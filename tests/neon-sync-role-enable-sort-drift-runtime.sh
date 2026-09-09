#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_sort = on;
alter role cycle_app set enable_indexscan = on;
alter role cycle_app set enable_indexonlyscan = off;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_sort = off;
alter role cycle_app set enable_indexscan = on;
alter role cycle_app set enable_indexonlyscan = off;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.sort_probe (id integer primary key, sort_key integer not null, payload text not null);
create index sort_probe_sort_key_idx on public.sort_probe(sort_key);
grant usage on schema public to cycle_app;
grant select on public.products, public.sort_probe to cycle_app;
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.sort_probe
select g, ((g::bigint * 7919) % 30001)::int, repeat(md5(g::text), 4)
from generate_series(1,30000) g;
analyze public.products;
analyze public.sort_probe;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_sort=%';"
}
probe_plan() {
  local url="$1" setting plan digest row
  setting="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_sort;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) select id,sort_key from public.sort_probe order by sort_key;" | tr '\n' ';')"
  digest="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "select md5(string_agg(id::text || ':' || sort_key::text, ',' order by sort_key)) from public.sort_probe;")"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  printf '%s|%s|digest=%s|%s' "$setting" "$plan" "$digest" "$row"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"; destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_plan "$SOURCE_APP_URL")"; destination_probe="$(probe_plan "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app sort probe=%s\ndestination app sort probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"
[[ "${source_setting,,}" == 'enable_sort=on' && "${destination_setting,,}" == 'enable_sort=off' ]] || { echo 'Fixture did not establish enable_sort drift.' >&2; exit 2; }
source_digest="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$source_probe")"
destination_digest="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$destination_probe")"
[[ -n "$source_digest" && "$source_digest" == "$destination_digest" ]] || { echo 'Sorted application results diverged unexpectedly.' >&2; exit 2; }
[[ "$source_probe" == on\|*"Sort"*"Seq Scan on sort_probe"*"|digest="*"|15000|SOURCE-SKU-15000|0" ]] || { echo "Source did not choose Sort + Seq Scan as expected: $source_probe" >&2; exit 2; }
[[ "$destination_probe" == off\|*"Index Scan using sort_probe_sort_key_idx on sort_probe"*"|digest="*"|15000|SOURCE-SKU-15000|0" && "$destination_probe" != *"Sort;"* ]] || { echo "Destination did not avoid Sort via index order as expected: $destination_probe" >&2; exit 2; }

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_SORT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enable_sort|pg_db_role_setting|role setting' <<<"$runtime_output"; then echo 'NEON_ROLE_ENABLE_SORT_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_ROLE_ENABLE_SORT_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
source_probe_after="$(probe_plan "$SOURCE_APP_URL")"; destination_probe_after="$(probe_plan "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app sort probe=%s\ndestination app sort probe=%s\nNEON_ROLE_ENABLE_SORT_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row" "$source_probe_after" "$destination_probe_after" "$sync_exit"
source_digest_after="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$source_probe_after")"
destination_digest_after="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$destination_probe_after")"
if [[ -z "$source_digest_after" || "$source_digest_after" != "$destination_digest_after" || "$source_probe_after" != on\|*"Sort"*"Seq Scan on sort_probe"*"|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" != off\|*"Index Scan using sort_probe_sort_key_idx on sort_probe"*"|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" == *"Sort;"* ]]; then
  echo 'Post-sync fixture/data no longer isolates the intended enable_sort boundary.' >&2
  exit 2
fi
if [[ "${destination_setting_after,,}" == 'enable_sort=on' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$destination_probe_after" == on\|*"Sort"* ]]; then echo 'NEON_ROLE_ENABLE_SORT_DRIFT_DETECTED=true'; exit 0; fi
echo 'NEON_ROLE_ENABLE_SORT_DRIFT_DETECTED=false'
exit 1

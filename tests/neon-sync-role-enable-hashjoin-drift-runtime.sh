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
alter role cycle_app set enable_hashjoin = on;
alter role cycle_app set enable_nestloop = off;
alter role cycle_app set enable_indexscan = off;
alter role cycle_app set enable_indexonlyscan = off;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_hashjoin = off;
alter role cycle_app set enable_nestloop = off;
alter role cycle_app set enable_indexscan = off;
alter role cycle_app set enable_indexonlyscan = off;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.join_left (id integer primary key, payload text not null);
create table public.join_right (id integer primary key, payload text not null);
grant usage on schema public to cycle_app;
grant select on public.products, public.join_left, public.join_right to cycle_app;
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.join_left select g, 'L-' || g from generate_series(1,20000) g;
insert into public.join_right select g, 'R-' || g from generate_series(1,20000) g;
analyze public.products; analyze public.join_left; analyze public.join_right;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_hashjoin=%';"
}
probe_plan() {
  local url="$1" hashjoin plan result row
  hashjoin="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_hashjoin;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'explain (costs off) select count(*) from public.join_left l join public.join_right r on r.id=l.id;' | tr '\n' ';')"
  result="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'select count(*) from public.join_left l join public.join_right r on r.id=l.id;')"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  printf '%s|%s|count=%s|%s' "$hashjoin" "$plan" "$result" "$row"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"; destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_plan "$SOURCE_APP_URL")"; destination_probe="$(probe_plan "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app join probe=%s\ndestination app join probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"
[[ "${source_setting,,}" == 'enable_hashjoin=on' && "${destination_setting,,}" == 'enable_hashjoin=off' ]] || { echo 'Fixture did not establish enable_hashjoin drift.' >&2; exit 2; }
[[ "$source_probe" == on\|*"Hash Join"*"|count=20000|15000|SOURCE-SKU-15000|0" ]] || { echo "Source did not use expected Hash Join: $source_probe" >&2; exit 2; }
[[ "$destination_probe" == off\|*"Merge Join"*"Sort"*"|count=20000|15000|SOURCE-SKU-15000|0" && "$destination_probe" != *"Hash Join"* ]] || { echo "Destination did not use expected Merge Join fallback: $destination_probe" >&2; exit 2; }

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_HASHJOIN_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enable_hashjoin|pg_db_role_setting|role setting' <<<"$runtime_output"; then echo 'NEON_ROLE_ENABLE_HASHJOIN_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_ROLE_ENABLE_HASHJOIN_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
source_probe_after="$(probe_plan "$SOURCE_APP_URL")"; destination_probe_after="$(probe_plan "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app join probe=%s\ndestination app join probe=%s\nNEON_ROLE_ENABLE_HASHJOIN_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row" "$source_probe_after" "$destination_probe_after" "$sync_exit"
if [[ "$source_probe_after" != on\|*"Hash Join"*"|count=20000|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" != off\|*"Merge Join"*"Sort"*"|count=20000|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" == *"Hash Join"* ]]; then
  echo 'Post-sync fixture/data no longer isolates the intended enable_hashjoin planner boundary.' >&2
  exit 2
fi
if [[ "${destination_setting_after,,}" == 'enable_hashjoin=on' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$destination_probe_after" == on\|*"Hash Join"* ]]; then echo 'NEON_ROLE_ENABLE_HASHJOIN_DRIFT_DETECTED=true'; exit 0; fi
echo 'NEON_ROLE_ENABLE_HASHJOIN_DRIFT_DETECTED=false'
exit 1

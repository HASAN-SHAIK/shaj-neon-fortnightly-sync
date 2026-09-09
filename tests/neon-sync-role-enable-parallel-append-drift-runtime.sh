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
alter role cycle_app set enable_parallel_append = on;
alter role cycle_app set max_parallel_workers_per_gather = 4;
alter role cycle_app set min_parallel_table_scan_size = 0;
alter role cycle_app set parallel_setup_cost = 0;
alter role cycle_app set parallel_tuple_cost = 0;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_parallel_append = off;
alter role cycle_app set max_parallel_workers_per_gather = 4;
alter role cycle_app set min_parallel_table_scan_size = 0;
alter role cycle_app set parallel_setup_cost = 0;
alter role cycle_app set parallel_tuple_cost = 0;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.parallel_append_probe (
  id integer not null,
  bucket integer not null,
  value integer not null
) partition by range (id);
create table public.parallel_append_probe_p1 partition of public.parallel_append_probe for values from (1) to (30001);
create table public.parallel_append_probe_p2 partition of public.parallel_append_probe for values from (30001) to (60001);
create table public.parallel_append_probe_p3 partition of public.parallel_append_probe for values from (60001) to (90001);
create table public.parallel_append_probe_p4 partition of public.parallel_append_probe for values from (90001) to (120001);
create table public.parallel_append_probe_p5 partition of public.parallel_append_probe for values from (120001) to (150001);
create table public.parallel_append_probe_p6 partition of public.parallel_append_probe for values from (150001) to (180001);
create table public.parallel_append_probe_p7 partition of public.parallel_append_probe for values from (180001) to (210001);
create table public.parallel_append_probe_p8 partition of public.parallel_append_probe for values from (210001) to (240001);
grant usage on schema public to cycle_app;
grant select on public.products, public.parallel_append_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100
from generate_series(1,20000) g;
insert into public.parallel_append_probe
select g, g % 97, ((g::bigint * 7919) % 100003)::int
from generate_series(1,240000) g;
analyze public.products;
analyze public.parallel_append_probe;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_parallel_append=%';"
}

probe_plan() {
  local url="$1" setting plan result row
  setting="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_parallel_append;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) select sum(value) from public.parallel_append_probe;" | tr '\n' ';')"
  result="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "select sum(value) from public.parallel_append_probe;")"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  printf '%s|%s|sum=%s|%s' "$setting" "$plan" "$result" "$row"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_plan "$SOURCE_APP_URL")"
destination_probe="$(probe_plan "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app parallel-append probe=%s\ndestination app parallel-append probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"

[[ "${source_setting,,}" == 'enable_parallel_append=on' && "${destination_setting,,}" == 'enable_parallel_append=off' ]] || { echo 'Fixture did not establish enable_parallel_append drift.' >&2; exit 2; }
source_sum="$(sed -n 's/.*|sum=\([^|]*\)|.*/\1/p' <<<"$source_probe")"
destination_sum="$(sed -n 's/.*|sum=\([^|]*\)|.*/\1/p' <<<"$destination_probe")"
[[ -n "$source_sum" && "$source_sum" == "$destination_sum" ]] || { echo 'Aggregate application results diverged unexpectedly.' >&2; exit 2; }
[[ "$source_probe" == on\|*"Gather"*"Partial Aggregate"*"Parallel Append"*"Parallel Seq Scan on parallel_append_probe_p"*"|sum="*"|15000|SOURCE-SKU-15000|0" ]] || { echo "Source did not choose Parallel Append as expected: $source_probe" >&2; exit 2; }
[[ "$destination_probe" == off\|*"Gather"*"Partial Aggregate"*"Append"*"Parallel Seq Scan on parallel_append_probe_p"*"|sum="*"|15000|SOURCE-SKU-15000|0" && "$destination_probe" != *"Parallel Append"* ]] || { echo "Destination did not choose non-parallel Append as expected: $destination_probe" >&2; exit 2; }

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" EXCLUDED_TABLES='public.parallel_append_probe,public.parallel_append_probe_p1,public.parallel_append_probe_p2,public.parallel_append_probe_p3,public.parallel_append_probe_p4,public.parallel_append_probe_p5,public.parallel_append_probe_p6,public.parallel_append_probe_p7,public.parallel_append_probe_p8' bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_PARALLEL_APPEND_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enable_parallel_append|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_ENABLE_PARALLEL_APPEND_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_ENABLE_PARALLEL_APPEND_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
source_probe_after="$(probe_plan "$SOURCE_APP_URL")"
destination_probe_after="$(probe_plan "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app parallel-append probe=%s\ndestination app parallel-append probe=%s\nNEON_ROLE_ENABLE_PARALLEL_APPEND_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row" "$source_probe_after" "$destination_probe_after" "$sync_exit"

source_sum_after="$(sed -n 's/.*|sum=\([^|]*\)|.*/\1/p' <<<"$source_probe_after")"
destination_sum_after="$(sed -n 's/.*|sum=\([^|]*\)|.*/\1/p' <<<"$destination_probe_after")"
[[ "${destination_setting_after,,}" == 'enable_parallel_append=off' ]] || { echo 'Destination enable_parallel_append setting changed unexpectedly.' >&2; exit 2; }
[[ "$destination_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
[[ -n "$source_sum_after" && "$source_sum_after" == "$destination_sum_after" ]] || { echo 'Post-sync aggregate application results diverged unexpectedly.' >&2; exit 2; }
[[ "$source_probe_after" == on\|*"Parallel Append"*"Parallel Seq Scan on parallel_append_probe_p"* ]] || { echo 'Source Parallel Append plan did not persist after sync.' >&2; exit 2; }
[[ "$destination_probe_after" == off\|*"Append"*"Parallel Seq Scan on parallel_append_probe_p"* && "$destination_probe_after" != *"Parallel Append"* ]] || { echo 'Destination non-Parallel-Append plan did not persist after sync.' >&2; exit 2; }

echo 'NEON_ROLE_ENABLE_PARALLEL_APPEND_DRIFT_DETECTED=false'
exit 1

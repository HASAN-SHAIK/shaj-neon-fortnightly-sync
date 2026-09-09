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
alter role cycle_app set enable_partition_pruning = on;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_partition_pruning = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create schema probe;
create table probe.sales_partitioned (
  id bigint not null,
  sale_day date not null,
  amount integer not null
) partition by range (sale_day);
create table probe.sales_jan partition of probe.sales_partitioned for values from ('2026-01-01') to ('2026-02-01');
create table probe.sales_feb partition of probe.sales_partitioned for values from ('2026-02-01') to ('2026-03-01');
grant usage on schema public, probe to cycle_app;
grant select on public.products, probe.sales_partitioned, probe.sales_jan, probe.sales_feb to cycle_app;
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into probe.sales_partitioned select g, date '2026-01-15', g % 1000 from generate_series(1,10000) g;
insert into probe.sales_partitioned select 10000 + g, date '2026-02-15', g % 1000 from generate_series(1,10000) g;
analyze public.products;
analyze probe.sales_partitioned;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_partition_pruning=%';"
}
probe_plan() {
  local url="$1" pruning plan result row
  pruning="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_partition_pruning;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) select count(*) from probe.sales_partitioned where sale_day = date '2026-01-15';" | tr '\n' ';')"
  result="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "select count(*) from probe.sales_partitioned where sale_day = date '2026-01-15';")"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  printf '%s|%s|count=%s|%s' "$pruning" "$plan" "$result" "$row"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"; destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_plan "$SOURCE_APP_URL")"; destination_probe="$(probe_plan "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app partition-pruning probe=%s\ndestination app partition-pruning probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"
[[ "${source_setting,,}" == 'enable_partition_pruning=on' && "${destination_setting,,}" == 'enable_partition_pruning=off' ]] || { echo 'Fixture did not establish enable_partition_pruning drift.' >&2; exit 2; }
[[ "$source_probe" == on\|*"Seq Scan on sales_jan"*"|count=10000|15000|SOURCE-SKU-15000|0" && "$source_probe" != *"sales_feb"* ]] || { echo "Source did not prune the February partition as expected: $source_probe" >&2; exit 2; }
[[ "$destination_probe" == off\|*"Append"*"sales_jan"*"sales_feb"*"|count=10000|15000|SOURCE-SKU-15000|0" ]] || { echo "Destination did not retain both partitions with pruning disabled: $destination_probe" >&2; exit 2; }

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" EXCLUDED_TABLES='probe.sales_partitioned,probe.sales_jan,probe.sales_feb' bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_PARTITION_PRUNING_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enable_partition_pruning|pg_db_role_setting|role setting' <<<"$runtime_output"; then echo 'NEON_ROLE_ENABLE_PARTITION_PRUNING_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_ROLE_ENABLE_PARTITION_PRUNING_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
source_probe_after="$(probe_plan "$SOURCE_APP_URL")"; destination_probe_after="$(probe_plan "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app partition-pruning probe=%s\ndestination app partition-pruning probe=%s\nNEON_ROLE_ENABLE_PARTITION_PRUNING_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row" "$source_probe_after" "$destination_probe_after" "$sync_exit"
if [[ "$source_probe_after" != on\|*"Seq Scan on sales_jan"*"|count=10000|15000|SOURCE-SKU-15000|0" || "$source_probe_after" == *"sales_feb"* || "$destination_probe_after" != off\|*"Append"*"sales_jan"*"sales_feb"*"|count=10000|15000|SOURCE-SKU-15000|0" ]]; then
  echo 'Post-sync fixture/data no longer isolates the intended enable_partition_pruning boundary.' >&2
  exit 2
fi
if [[ "${destination_setting_after,,}" == 'enable_partition_pruning=on' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$destination_probe_after" == on\|*"Seq Scan on sales_jan"* && "$destination_probe_after" != *"sales_feb"* ]]; then echo 'NEON_ROLE_ENABLE_PARTITION_PRUNING_DRIFT_DETECTED=true'; exit 0; fi
echo 'NEON_ROLE_ENABLE_PARTITION_PRUNING_DRIFT_DETECTED=false'
exit 1

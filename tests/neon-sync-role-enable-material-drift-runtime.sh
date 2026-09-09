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
alter role cycle_app set enable_material = on;
alter role cycle_app set enable_hashjoin = off;
alter role cycle_app set enable_mergejoin = off;
alter role cycle_app set enable_nestloop = on;
alter role cycle_app set enable_memoize = off;
alter role cycle_app set enable_indexscan = off;
alter role cycle_app set enable_indexonlyscan = off;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_material = off;
alter role cycle_app set enable_hashjoin = off;
alter role cycle_app set enable_mergejoin = off;
alter role cycle_app set enable_nestloop = on;
alter role cycle_app set enable_memoize = off;
alter role cycle_app set enable_indexscan = off;
alter role cycle_app set enable_indexonlyscan = off;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.material_outer (id integer primary key, bucket integer not null);
create table public.material_inner (id integer primary key, bucket integer not null);
grant usage on schema public to cycle_app;
grant select on public.products, public.material_outer, public.material_inner to cycle_app;
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.material_outer select g, g % 10 from generate_series(1,1000) g;
insert into public.material_inner select g, g % 10 from generate_series(1,20) g;
analyze public.products;
analyze public.material_outer;
analyze public.material_inner;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_material=%';"
}
probe_plan() {
  local url="$1" material plan result row
  material="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_material;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) select count(*) from public.material_outer o join public.material_inner i on i.bucket = o.bucket;" | tr '\n' ';')"
  result="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "select count(*) from public.material_outer o join public.material_inner i on i.bucket = o.bucket;")"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  printf '%s|%s|count=%s|%s' "$material" "$plan" "$result" "$row"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"; destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_plan "$SOURCE_APP_URL")"; destination_probe="$(probe_plan "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app material probe=%s\ndestination app material probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"
[[ "${source_setting,,}" == 'enable_material=on' && "${destination_setting,,}" == 'enable_material=off' ]] || { echo 'Fixture did not establish enable_material drift.' >&2; exit 2; }
[[ "$source_probe" == on\|*"Nested Loop"*"Materialize"*"|count=2000|15000|SOURCE-SKU-15000|0" ]] || { echo "Source did not use planner materialization as expected: $source_probe" >&2; exit 2; }
[[ "$destination_probe" == off\|*"Nested Loop"*"|count=2000|15000|SOURCE-SKU-15000|0" && "$destination_probe" != *"Materialize"* ]] || { echo "Destination did not avoid planner materialization as expected: $destination_probe" >&2; exit 2; }

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_MATERIAL_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enable_material|pg_db_role_setting|role setting' <<<"$runtime_output"; then echo 'NEON_ROLE_ENABLE_MATERIAL_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_ROLE_ENABLE_MATERIAL_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
source_probe_after="$(probe_plan "$SOURCE_APP_URL")"; destination_probe_after="$(probe_plan "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app material probe=%s\ndestination app material probe=%s\nNEON_ROLE_ENABLE_MATERIAL_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row" "$source_probe_after" "$destination_probe_after" "$sync_exit"
if [[ "$source_probe_after" != on\|*"Nested Loop"*"Materialize"*"|count=2000|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" != off\|*"Nested Loop"*"|count=2000|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" == *"Materialize"* ]]; then
  echo 'Post-sync fixture/data no longer isolates the intended enable_material boundary.' >&2
  exit 2
fi
if [[ "${destination_setting_after,,}" == 'enable_material=on' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$destination_probe_after" == on\|*"Materialize"* ]]; then echo 'NEON_ROLE_ENABLE_MATERIAL_DRIFT_DETECTED=true'; exit 0; fi
echo 'NEON_ROLE_ENABLE_MATERIAL_DRIFT_DETECTED=false'
exit 1

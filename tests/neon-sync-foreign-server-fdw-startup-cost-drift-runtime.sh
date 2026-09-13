#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login;"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

setup_db() {
  local admin_url="$1" startup_cost="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v startup_cost="$startup_cost" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, fdw_startup_cost %L)', current_database(), :'startup_cost') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'products');
grant select on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" 100
setup_db "$DESTINATION_ADMIN_URL" 10000

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
insert into public.products
select g, 'SKU-' || g, g % 17 from generate_series(1,2000) g;
analyze public.products;
SQL
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
insert into public.products
select g, 'SKU-' || g, g % 17 from generate_series(1,2000) g;
analyze public.products;
SQL

server_startup_cost() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='fdw_startup_cost';"
}

application_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select count(*),sum(quantity) from public.products_remote;"
}

plan_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "explain (costs on, verbose off) select id,sku,quantity from public.products_remote where quantity=7 order by id limit 25;"
}

source_option_before="$(server_startup_cost "$SOURCE_ADMIN_URL")"
destination_option_before="$(server_startup_cost "$DESTINATION_ADMIN_URL")"
source_app_before="$(application_probe "$SOURCE_APP_URL")"
destination_app_before="$(application_probe "$DESTINATION_APP_URL")"
source_plan_before="$(plan_probe "$SOURCE_APP_URL")"
destination_plan_before="$(plan_probe "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource fdw_startup_cost=%s\ndestination fdw_startup_cost=%s\n' "$source_option_before" "$destination_option_before"
printf 'source application probe=%s\ndestination application probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'SOURCE PLAN BEFORE\n%s\nDESTINATION PLAN BEFORE\n%s\n' "$source_plan_before" "$destination_plan_before"

if [[ "$source_option_before" != 100 || "$destination_option_before" != 10000 || "$source_app_before" != "$destination_app_before" || "$source_plan_before" == "$destination_plan_before" ]]; then
  echo 'Fixture did not establish isolated fdw_startup_cost planning drift with equal application results.' >&2
  exit 2
fi
if ! grep -q 'Foreign Scan' <<<"$source_plan_before" || ! grep -q 'Foreign Scan' <<<"$destination_plan_before"; then
  echo 'Fixture did not exercise a real postgres_fdw Foreign Scan.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2001,'SOURCE-SKU-2001',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_FDW_STARTUP_COST_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'fdw_startup_cost|startup cost|foreign server.*(cost|option|drift|mismatch)' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_FDW_STARTUP_COST_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_FDW_STARTUP_COST_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_option_after="$(server_startup_cost "$DESTINATION_ADMIN_URL")"
destination_row_2001="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2001;")"
source_app_after="$(application_probe "$SOURCE_APP_URL")"
destination_app_after="$(application_probe "$DESTINATION_APP_URL")"
source_plan_after="$(plan_probe "$SOURCE_APP_URL")"
destination_plan_after="$(plan_probe "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination fdw_startup_cost=%s\nappended source row=%s\n' "$destination_option_after" "$destination_row_2001"
printf 'source application probe=%s\ndestination application probe=%s\n' "$source_app_after" "$destination_app_after"
printf 'SOURCE PLAN AFTER\n%s\nDESTINATION PLAN AFTER\n%s\n' "$source_plan_after" "$destination_plan_after"
printf 'NEON_FOREIGN_SERVER_FDW_STARTUP_COST_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_option_after" == 100 && "$destination_row_2001" == '2001|SOURCE-SKU-2001|11' && "$source_app_after" == "$destination_app_after" && "$source_plan_after" == "$destination_plan_after" ]]; then
  echo 'NEON_FOREIGN_SERVER_FDW_STARTUP_COST_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_option_after" == 10000 && "$destination_row_2001" == '2001|SOURCE-SKU-2001|11' && "$source_app_after" == "$destination_app_after" && "$source_plan_before" == "$source_plan_after" && "$destination_plan_before" == "$destination_plan_after" && "$source_plan_after" != "$destination_plan_after" ]]; then
  echo 'NEON_FOREIGN_SERVER_FDW_STARTUP_COST_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_FDW_STARTUP_COST_PLAN_DIVERGENCE=true'
  echo 'Destination retained a different postgres_fdw startup-cost policy; production synchronization succeeded while real Foreign Scan planner costs remained different from source.' >&2
  exit 1
fi

echo 'Post-sync fdw_startup_cost scenario produced an unexpected runtime state.' >&2
exit 2

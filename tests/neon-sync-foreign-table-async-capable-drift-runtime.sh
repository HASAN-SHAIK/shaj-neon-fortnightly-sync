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
  local admin_url="$1" dbname="$2" first_table_async="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v first_table_async="$first_table_async" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create table public.remote_a(id bigint primary key, quantity integer not null);
create table public.remote_b(id bigint primary key, quantity integer not null);
insert into public.remote_a values (1,7);
insert into public.remote_b values (101,11);
grant usage on schema public to cycle_app;
grant select on public.remote_a, public.remote_b to cycle_app;
select format('create server retail_async_a foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, async_capable ''true'')', :'dbname') \gexec
select format('create server retail_async_b foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, async_capable ''true'')', :'dbname') \gexec
create user mapping for cycle_app server retail_async_a options (user 'cycle_app', password_required 'false');
create user mapping for cycle_app server retail_async_b options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_async_a options (user 'postgres', password_required 'false');
create user mapping for postgres server retail_async_b options (user 'postgres', password_required 'false');
create table public.async_products(id bigint, quantity integer) partition by range(id);
select format('create foreign table public.async_products_a partition of public.async_products for values from (0) to (100) server retail_async_a options (schema_name ''public'', table_name ''remote_a'', async_capable %L)', :'first_table_async') \gexec
create foreign table public.async_products_b partition of public.async_products for values from (100) to (200)
  server retail_async_b options (schema_name 'public', table_name 'remote_b', async_capable 'true');
grant select on public.async_products to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source true
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination false
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

table_async() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select ftoptions from pg_foreign_table where ftrelid='public.async_products_a'::regclass)) where option_name='async_capable';"
}
server_async() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_async_a')) where option_name='async_capable';"
}
app_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select count(*),coalesce(sum(quantity),0) from public.async_products;"
}
app_plan() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "explain (verbose, costs off) select * from public.async_products;"
}
async_count() {
  local plan="$1"
  grep -c 'Async Foreign Scan' <<<"$plan" || true
}

source_table_before="$(table_async "$SOURCE_ADMIN_URL")"
destination_table_before="$(table_async "$DESTINATION_ADMIN_URL")"
source_server_before="$(server_async "$SOURCE_ADMIN_URL")"
destination_server_before="$(server_async "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_read "$SOURCE_APP_URL")"
destination_read_before="$(app_read "$DESTINATION_APP_URL")"
source_plan_before="$(app_plan "$SOURCE_APP_URL")"
destination_plan_before="$(app_plan "$DESTINATION_APP_URL")"
source_async_before="$(async_count "$source_plan_before")"
destination_async_before="$(async_count "$destination_plan_before")"

printf 'BEFORE\nsource table async_capable=%s\ndestination table async_capable=%s\n' "$source_table_before" "$destination_table_before"
printf 'source server async_capable=%s\ndestination server async_capable=%s\n' "$source_server_before" "$destination_server_before"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_before" "$destination_read_before"
printf 'source async scans=%s\ndestination async scans=%s\n' "$source_async_before" "$destination_async_before"
printf 'SOURCE PLAN\n%s\nDESTINATION PLAN\n%s\n' "$source_plan_before" "$destination_plan_before"

if [[ "$source_table_before" != true || "$destination_table_before" != false || "$source_server_before" != true || "$destination_server_before" != true || "$source_read_before" != '2|18' || "$destination_read_before" != '2|18' || "$source_async_before" -ne 2 || "$destination_async_before" -ne 1 ]]; then
  echo 'Fixture did not establish isolated foreign-table async_capable override drift with observable asynchronous Append planning.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_TABLE_ASYNC_CAPABLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign table.*(async_capable|async capable|option|incompatib|drift|mismatch)|(async_capable|async capable|option|drift|mismatch).*foreign table' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_TABLE_ASYNC_CAPABLE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_TABLE_ASYNC_CAPABLE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_table_after="$(table_async "$DESTINATION_ADMIN_URL")"
destination_server_after="$(server_async "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_read_after="$(app_read "$SOURCE_APP_URL")"
destination_read_after="$(app_read "$DESTINATION_APP_URL")"
source_plan_after="$(app_plan "$SOURCE_APP_URL")"
destination_plan_after="$(app_plan "$DESTINATION_APP_URL")"
source_async_after="$(async_count "$source_plan_after")"
destination_async_after="$(async_count "$destination_plan_after")"

printf 'AFTER\ndestination table async_capable=%s\ndestination server async_capable=%s\nappended source row=%s\n' "$destination_table_after" "$destination_server_after" "$destination_row_2"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_after" "$destination_read_after"
printf 'source async scans=%s\ndestination async scans=%s\n' "$source_async_after" "$destination_async_after"
printf 'SOURCE PLAN AFTER\n%s\nDESTINATION PLAN AFTER\n%s\n' "$source_plan_after" "$destination_plan_after"
printf 'NEON_FOREIGN_TABLE_ASYNC_CAPABLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_table_after" == true && "$destination_server_after" == true && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' && "$source_async_after" -eq 2 && "$destination_async_after" -eq 2 ]]; then
  echo 'NEON_FOREIGN_TABLE_ASYNC_CAPABLE_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_table_after" == false && "$destination_server_after" == true && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' && "$source_async_after" -eq 2 && "$destination_async_after" -eq 1 ]]; then
  echo 'NEON_FOREIGN_TABLE_ASYNC_CAPABLE_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_TABLE_ASYNC_CAPABLE_PLAN_DIVERGENCE=true'
  echo 'Destination retained table-level async_capable=false; production synchronization succeeded while identical application results used a different synchronous/asynchronous Append execution policy.' >&2
  exit 1
fi

echo 'Post-sync foreign-table async_capable scenario produced an unexpected runtime state.' >&2
exit 2

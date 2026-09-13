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
  local admin_url="$1" fetch_size="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v fetch_size="$fetch_size" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, fetch_size %L)', current_database(), :'fetch_size') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'products');
grant select on public.products_remote to cycle_app;
insert into public.products
select g, 'SKU-' || g::text, (g % 17)::int from generate_series(1,250) g;
SQL
}

setup_db "$SOURCE_ADMIN_URL" 100
setup_db "$DESTINATION_ADMIN_URL" 10

server_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='fetch_size';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c 'select count(*), sum(quantity) from public.products_remote;'
}

source_before="$(server_option "$SOURCE_ADMIN_URL")"
destination_before="$(server_option "$DESTINATION_ADMIN_URL")"
source_probe_before="$(app_probe "$SOURCE_APP_URL")"
destination_probe_before="$(app_probe "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource fetch_size=%s\ndestination fetch_size=%s\nsource application probe=%s\ndestination application probe=%s\n' \
  "$source_before" "$destination_before" "$source_probe_before" "$destination_probe_before"

if [[ "$source_before" != 100 || "$destination_before" != 10 || "$source_probe_before" != "$destination_probe_before" || "$source_probe_before" != '250|1995' ]]; then
  echo 'Fixture did not establish isolated foreign-server fetch_size drift with equivalent application results.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (251,'SOURCE-SKU-251',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_FETCH_SIZE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*fetch_size|fetch_size.*(drift|mismatch)' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_FETCH_SIZE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_FETCH_SIZE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_after="$(server_option "$DESTINATION_ADMIN_URL")"
source_probe_after="$(app_probe "$SOURCE_APP_URL")"
destination_probe_after="$(app_probe "$DESTINATION_APP_URL")"
destination_row="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=251;")"

printf 'AFTER\ndestination fetch_size=%s\nsource application probe=%s\ndestination application probe=%s\nappended source row=%s\n' \
  "$destination_after" "$source_probe_after" "$destination_probe_after" "$destination_row"
printf 'NEON_FOREIGN_SERVER_FETCH_SIZE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_after" == 100 && "$source_probe_after" == "$destination_probe_after" && "$destination_row" == '251|SOURCE-SKU-251|11' ]]; then
  echo 'NEON_FOREIGN_SERVER_FETCH_SIZE_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_after" == 10 && "$source_probe_after" == "$destination_probe_after" && "$destination_row" == '251|SOURCE-SKU-251|11' ]]; then
  echo 'NEON_FOREIGN_SERVER_FETCH_SIZE_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_FETCH_SIZE_POLICY_DIVERGENCE=true'
  exit 1
fi

echo 'Post-sync fetch_size scenario produced an unexpected runtime state.' >&2
exit 2

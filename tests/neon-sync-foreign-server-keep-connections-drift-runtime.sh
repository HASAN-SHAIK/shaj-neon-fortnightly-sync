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
  local admin_url="$1" keep_connections="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v keep_connections="$keep_connections" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, keep_connections %L)', current_database(), :'keep_connections') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'products');
grant select on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" true
setup_db "$DESTINATION_ADMIN_URL" false
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_keep_connections_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='keep_connections';"
}

connection_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At <<'SQL'
select count(*) from public.products_remote;
select count(*) from postgres_fdw_get_connections() where server_name='retail_loopback';
SQL
}

source_option_before="$(server_keep_connections_option "$SOURCE_ADMIN_URL")"
destination_option_before="$(server_keep_connections_option "$DESTINATION_ADMIN_URL")"
source_probe_before="$(connection_probe "$SOURCE_APP_URL")"
destination_probe_before="$(connection_probe "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource foreign server keep_connections=%s\ndestination foreign server keep_connections=%s\n' "$source_option_before" "$destination_option_before"
printf 'source application connection probe=%s\ndestination application connection probe=%s\n' "$source_probe_before" "$destination_probe_before"

if [[ "$source_option_before" != true || "$destination_option_before" != false || "$source_probe_before" != $'1\n1' || "$destination_probe_before" != $'1\n0' ]]; then
  echo 'Fixture did not establish isolated foreign-server keep_connections behavior drift.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_KEEP_CONNECTIONS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(keep_connections|connection|option|incompatib|drift|mismatch)|(keep_connections|connection|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_KEEP_CONNECTIONS_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_KEEP_CONNECTIONS_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_option_after="$(server_keep_connections_option "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(connection_probe "$SOURCE_APP_URL")"
destination_probe_after="$(connection_probe "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination foreign server keep_connections=%s\nappended source row=%s\n' "$destination_option_after" "$destination_row_2"
printf 'source application connection probe=%s\ndestination application connection probe=%s\n' "$source_probe_after" "$destination_probe_after"
printf 'NEON_FOREIGN_SERVER_KEEP_CONNECTIONS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_option_after" == true && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_probe_after" == $'2\n1' && "$destination_probe_after" == $'2\n1' ]]; then
  echo 'NEON_FOREIGN_SERVER_KEEP_CONNECTIONS_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_option_after" == false && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_probe_after" == $'2\n1' && "$destination_probe_after" == $'2\n0' ]]; then
  echo 'NEON_FOREIGN_SERVER_KEEP_CONNECTIONS_DRIFT_DETECTED=false'
  echo 'Destination retained an incompatible foreign-server keep_connections policy; production synchronization succeeded while application connection lifecycle behavior remained different from source.' >&2
  exit 1
fi

echo 'Post-sync foreign-server keep_connections scenario produced an unexpected runtime state.' >&2
exit 2

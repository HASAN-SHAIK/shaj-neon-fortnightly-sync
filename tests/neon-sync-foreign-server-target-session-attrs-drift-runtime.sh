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
  local admin_url="$1" dbname="$2" target_attrs="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v target_attrs="$target_attrs" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create table public.remote_products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.remote_products values (1,'REMOTE-SKU-1',7);
grant usage on schema public to cycle_app;
grant select on public.remote_products to cycle_app;
select format('alter role cycle_app in database %I set default_transaction_read_only = on', :'dbname') \gexec
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, target_session_attrs %L)', :'dbname', :'target_attrs') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_loopback options (user 'postgres', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer)
  server retail_loopback options (schema_name 'public', table_name 'remote_products');
grant select on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source any
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination read-write
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_target_attrs() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='target_session_attrs';"
}

app_read_capture() {
  local app_url="$1"
  set +e
  APP_READ_OUTPUT="$(psql "$app_url" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products_remote order by id;" 2>&1)"
  APP_READ_EXIT=$?
  set -e
}

source_attrs_before="$(server_target_attrs "$SOURCE_ADMIN_URL")"
destination_attrs_before="$(server_target_attrs "$DESTINATION_ADMIN_URL")"
app_read_capture "$SOURCE_APP_URL"; source_read_before_exit=$APP_READ_EXIT; source_read_before=$APP_READ_OUTPUT
app_read_capture "$DESTINATION_APP_URL"; destination_read_before_exit=$APP_READ_EXIT; destination_read_before=$APP_READ_OUTPUT

printf 'BEFORE\nsource foreign server target_session_attrs=%s\ndestination foreign server target_session_attrs=%s\n' "$source_attrs_before" "$destination_attrs_before"
printf 'source app foreign probe exit=%s\nsource app foreign probe=%s\n' "$source_read_before_exit" "$source_read_before"
printf 'destination app foreign probe exit=%s\ndestination app foreign probe=%s\n' "$destination_read_before_exit" "$destination_read_before"

if [[ "$source_attrs_before" != any || "$destination_attrs_before" != read-write || "$source_read_before_exit" -ne 0 || "$source_read_before" != '1|REMOTE-SKU-1|7' || "$destination_read_before_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated target_session_attrs drift with source read-only session accepted and destination read-write requirement rejected.' >&2
  exit 2
fi

if ! grep -Eqi 'session is not read-write|read-only|target_session_attrs|read.write|could not make a suitable connection|server does not satisfy' <<<"$destination_read_before"; then
  echo 'Destination failure did not expose a read-write target-session incompatibility.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_TARGET_SESSION_ATTRS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(target_session_attrs|target session|option|incompatib|drift|mismatch)|(target_session_attrs|target session|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_TARGET_SESSION_ATTRS_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_TARGET_SESSION_ATTRS_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_attrs_after="$(server_target_attrs "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
app_read_capture "$SOURCE_APP_URL"; source_read_after_exit=$APP_READ_EXIT; source_read_after=$APP_READ_OUTPUT
app_read_capture "$DESTINATION_APP_URL"; destination_read_after_exit=$APP_READ_EXIT; destination_read_after=$APP_READ_OUTPUT

printf 'AFTER\ndestination foreign server target_session_attrs=%s\nappended source row=%s\n' "$destination_attrs_after" "$destination_row_2"
printf 'source app foreign probe exit=%s\nsource app foreign probe=%s\n' "$source_read_after_exit" "$source_read_after"
printf 'destination app foreign probe exit=%s\ndestination app foreign probe=%s\n' "$destination_read_after_exit" "$destination_read_after"
printf 'NEON_FOREIGN_SERVER_TARGET_SESSION_ATTRS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_attrs_after" == any && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after_exit" -eq 0 && "$source_read_after" == '1|REMOTE-SKU-1|7' && "$destination_read_after_exit" -eq 0 && "$destination_read_after" == '1|REMOTE-SKU-1|7' ]]; then
  echo 'NEON_FOREIGN_SERVER_TARGET_SESSION_ATTRS_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_attrs_after" == read-write && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after_exit" -eq 0 && "$source_read_after" == '1|REMOTE-SKU-1|7' && "$destination_read_after_exit" -ne 0 ]]; then
  if grep -Eqi 'session is not read-write|read-only|target_session_attrs|read.write|could not make a suitable connection|server does not satisfy' <<<"$destination_read_after"; then
    echo 'NEON_FOREIGN_SERVER_TARGET_SESSION_ATTRS_DRIFT_DETECTED=false'
    echo 'NEON_FOREIGN_SERVER_TARGET_SESSION_ATTRS_APPLICATION_PATH_BROKEN=true'
    echo 'Destination retained target_session_attrs=read-write while the mapped application role is read-only; production synchronization reported success but the real destination FDW application path remained unavailable.' >&2
    exit 1
  fi
fi

echo 'Post-sync target_session_attrs scenario produced an unexpected runtime state.' >&2
exit 2

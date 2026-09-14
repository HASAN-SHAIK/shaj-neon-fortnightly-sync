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
  local admin_url="$1" dbname="$2" keepalive_idle="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v keepalive_idle="$keepalive_idle" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create table public.remote_products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.remote_products values (1,'REMOTE-SKU-1',7);
grant usage on schema public to cycle_app;
grant select, insert on public.remote_products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, keepalives_idle %L)', :'dbname', :'keepalive_idle') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_loopback options (user 'postgres', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer)
  server retail_loopback options (schema_name 'public', table_name 'remote_products');
grant select, insert on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source 5
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination 60
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_keepalives_idle() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='keepalives_idle';"
}
app_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products_remote order by id;"
}
app_write_probe() {
  local app_url="$1" admin_url="$2" probe_id="$3"
  psql "$app_url" -v ON_ERROR_STOP=1 -qAt <<SQL
begin;
insert into public.products_remote(id,sku,quantity) values ($probe_id,'PROBE-$probe_id',3);
select count(*) from public.products_remote where id=$probe_id;
rollback;
SQL
  psql "$admin_url" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.remote_products where id=$probe_id;"
}

source_keepalive_before="$(server_keepalives_idle "$SOURCE_ADMIN_URL")"
destination_keepalive_before="$(server_keepalives_idle "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_read "$SOURCE_APP_URL")"
destination_read_before="$(app_read "$DESTINATION_APP_URL")"
source_write_before="$(app_write_probe "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" 9201)"
destination_write_before="$(app_write_probe "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" 9202)"
printf 'BEFORE\nsource foreign server keepalives_idle=%s\ndestination foreign server keepalives_idle=%s\n' "$source_keepalive_before" "$destination_keepalive_before"
printf 'source app read=%s\ndestination app read=%s\nsource write probe=%s\ndestination write probe=%s\n' "$source_read_before" "$destination_read_before" "$source_write_before" "$destination_write_before"

if [[ "$source_keepalive_before" != 5 || "$destination_keepalive_before" != 60 || "$source_read_before" != '1|REMOTE-SKU-1|7' || "$destination_read_before" != '1|REMOTE-SKU-1|7' || "$source_write_before" != $'1\n0' || "$destination_write_before" != $'1\n0' ]]; then
  echo 'Fixture did not establish isolated keepalives_idle drift with equivalent real FDW read/write behavior.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"
set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_KEEPALIVES_IDLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(keepalives_idle|keepalive|option|incompatib|drift|mismatch)|(keepalives_idle|keepalive|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_KEEPALIVES_IDLE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_KEEPALIVES_IDLE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_keepalive_after="$(server_keepalives_idle "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_read_after="$(app_read "$SOURCE_APP_URL")"
destination_read_after="$(app_read "$DESTINATION_APP_URL")"
source_write_after="$(app_write_probe "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" 9211)"
destination_write_after="$(app_write_probe "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" 9212)"
printf 'AFTER\ndestination foreign server keepalives_idle=%s\nappended source row=%s\n' "$destination_keepalive_after" "$destination_row_2"
printf 'source app read=%s\ndestination app read=%s\nsource write probe=%s\ndestination write probe=%s\n' "$source_read_after" "$destination_read_after" "$source_write_after" "$destination_write_after"
printf 'NEON_FOREIGN_SERVER_KEEPALIVES_IDLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_keepalive_after" == 5 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '1|REMOTE-SKU-1|7' && "$destination_read_after" == '1|REMOTE-SKU-1|7' && "$source_write_after" == $'1\n0' && "$destination_write_after" == $'1\n0' ]]; then
  echo 'NEON_FOREIGN_SERVER_KEEPALIVES_IDLE_DRIFT_DETECTED=true'
  exit 0
fi
if [[ "$destination_keepalive_after" == 60 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '1|REMOTE-SKU-1|7' && "$destination_read_after" == '1|REMOTE-SKU-1|7' && "$source_write_after" == $'1\n0' && "$destination_write_after" == $'1\n0' ]]; then
  echo 'NEON_FOREIGN_SERVER_KEEPALIVES_IDLE_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_KEEPALIVES_IDLE_POLICY_DIVERGENCE=true'
  echo 'Destination retained keepalives_idle=60 while source requires 5; production synchronization reported success and both live FDW paths remained functionally usable.' >&2
  exit 1
fi

echo 'Post-sync keepalives_idle scenario produced an unexpected runtime state.' >&2
exit 2

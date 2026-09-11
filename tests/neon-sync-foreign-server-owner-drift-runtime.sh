#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

setup_db() {
  local admin_url="$1" owner="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v owner="$owner" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app, cycle_other;
grant select on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L)', current_database()) \gexec
select format('alter server retail_loopback owner to %I', :'owner') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password 'app', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer)
  server retail_loopback options (schema_name 'public', table_name 'products');
grant select on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_owner
setup_db "$DESTINATION_ADMIN_URL" cycle_other
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(s.srvowner) from pg_foreign_server s where s.srvname='retail_loopback';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products_remote order by id;"
}
break_server_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter server retail_loopback options (set dbname 'cycle_d_missing');"
}
restore_destination_server() {
  psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "alter server retail_loopback options (set dbname 'cycle_d_destination'); alter server retail_loopback owner to cycle_other;"
}

source_owner_before="$(server_owner "$SOURCE_ADMIN_URL")"
destination_owner_before="$(server_owner "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"
set +e
source_alter_output="$(break_server_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_alter_exit=$?
destination_alter_output="$(break_server_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_alter_exit=$?
destination_app_after_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_exit=$?
set -e
printf 'BEFORE\nsource foreign server owner=%s\ndestination foreign server owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source app foreign probe=%s\ndestination app foreign probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other alter exit=%s\nsource cycle_other output=%s\n' "$source_alter_exit" "$source_alter_output"
printf 'destination cycle_other alter exit=%s\ndestination cycle_other output=%s\n' "$destination_alter_exit" "$destination_alter_output"
printf 'destination app after owner mutation exit=%s\ndestination app after owner mutation output=%s\n' "$destination_app_after_exit" "$destination_app_after_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_app_before" != '1|BASE-SKU-1|7'
      || "$destination_app_before" != '1|BASE-SKU-1|7' || "$source_alter_exit" -eq 0 || "$destination_alter_exit" -ne 0 || "$destination_app_after_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated foreign-server ownership drift.' >&2
  exit 2
fi

restore_destination_server
[[ "$(server_owner "$DESTINATION_ADMIN_URL")" == cycle_other ]] || exit 2
[[ "$(app_probe "$DESTINATION_APP_URL")" == '1|BASE-SKU-1|7' ]] || exit 2
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(server_owner "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_app_before_final="$(app_probe "$DESTINATION_APP_URL")"
set +e
source_alter_after_output="$(break_server_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_alter_after_exit=$?
destination_alter_after_output="$(break_server_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_alter_after_exit=$?
destination_app_after_final_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_final_exit=$?
set -e
printf 'AFTER\ndestination foreign server owner=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_row_2"
printf 'destination app before final owner mutation=%s\n' "$destination_app_before_final"
printf 'source cycle_other final alter exit=%s\nsource cycle_other final output=%s\n' "$source_alter_after_exit" "$source_alter_after_output"
printf 'destination cycle_other final alter exit=%s\ndestination cycle_other final output=%s\n' "$destination_alter_after_exit" "$destination_alter_after_output"
printf 'destination app after final owner mutation exit=%s\ndestination app after final owner mutation output=%s\nNEON_FOREIGN_SERVER_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final_exit" "$destination_app_after_final_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_alter_after_exit" -ne 0 && "$destination_alter_after_exit" -ne 0 ]]; then
  echo 'NEON_FOREIGN_SERVER_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_app_before_final" == $'1|BASE-SKU-1|7\n2|SOURCE-SKU-2|11' && "$source_alter_after_exit" -ne 0 && "$destination_alter_after_exit" -eq 0 && "$destination_app_after_final_exit" -ne 0 ]]; then
  echo 'NEON_FOREIGN_SERVER_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained foreign-server owner authority denied on source; owner-only connection-option mutation broke the real application foreign-table path.' >&2
  exit 1
fi

echo 'Post-sync foreign-server ownership scenario produced an unexpected runtime state.' >&2
exit 2

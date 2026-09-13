#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'
for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login;"; done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'
setup_db() {
  local admin_url="$1" updatable="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v updatable="$updatable" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select,insert,update,delete on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, updatable %L)', current_database(), :'updatable') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'products');
grant select,insert,update,delete on public.products_remote to cycle_app;
insert into public.products values (1,'BASE-SKU-1',7);
SQL
}
setup_db "$SOURCE_ADMIN_URL" true
setup_db "$DESTINATION_ADMIN_URL" false
server_option() { psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='updatable';"; }
source_before="$(server_option "$SOURCE_ADMIN_URL")"; destination_before="$(server_option "$DESTINATION_ADMIN_URL")"
source_read="$(psql "$SOURCE_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products_remote order by id;')"
destination_read="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products_remote order by id;')"
set +e
source_write_output="$(psql "$SOURCE_APP_URL" -v ON_ERROR_STOP=1 -Atc "insert into public.products_remote values (10,'SOURCE-FDW-WRITE',10);" 2>&1)"; source_write_exit=$?
destination_write_output="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -Atc "insert into public.products_remote values (10,'DEST-FDW-WRITE',10);" 2>&1)"; destination_write_exit=$?
set -e
printf 'BEFORE\nsource updatable=%s\ndestination updatable=%s\nsource read=%s\ndestination read=%s\nsource write exit=%s\ndestination write exit=%s\n' "$source_before" "$destination_before" "$source_read" "$destination_read" "$source_write_exit" "$destination_write_exit"
printf 'destination write output=%s\n' "$destination_write_output"
if [[ "$source_before" != true || "$destination_before" != false || "$source_read" != "$destination_read" || "$source_write_exit" -ne 0 || "$destination_write_exit" -eq 0 ]]; then echo 'Fixture did not establish isolated server-level updatable drift.' >&2; exit 2; fi
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"
set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_UPDATABLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*updatable|updatable.*(drift|mismatch)' <<<"$runtime_output"; then echo 'NEON_FOREIGN_SERVER_UPDATABLE_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_FOREIGN_SERVER_UPDATABLE_DRIFT_FAIL_CLOSED=false'; exit 1
fi
destination_after="$(server_option "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_write_after_output="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -Atc "insert into public.products_remote values (20,'DEST-FDW-WRITE-AFTER',20);" 2>&1)"; destination_write_after_exit=$?
set -e
printf 'AFTER\ndestination updatable=%s\nappended source row=%s\ndestination write exit=%s\ndestination write output=%s\n' "$destination_after" "$destination_row" "$destination_write_after_exit" "$destination_write_after_output"
printf 'NEON_FOREIGN_SERVER_UPDATABLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
if [[ "$destination_after" == true && "$destination_row" == '2|SOURCE-SKU-2|11' && "$destination_write_after_exit" -eq 0 ]]; then echo 'NEON_FOREIGN_SERVER_UPDATABLE_DRIFT_DETECTED=true'; exit 0; fi
if [[ "$destination_after" == false && "$destination_row" == '2|SOURCE-SKU-2|11' && "$destination_write_after_exit" -ne 0 ]]; then echo 'NEON_FOREIGN_SERVER_UPDATABLE_DRIFT_DETECTED=false'; echo 'NEON_FOREIGN_SERVER_UPDATABLE_WRITE_PATH_BROKEN=true'; exit 1; fi
echo 'Post-sync server updatable scenario produced an unexpected runtime state.' >&2; exit 2

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
 local admin_url="$1" dbname="$2" binding="$3"
 psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v binding="$binding" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create table public.remote_products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.remote_products values (1,'REMOTE-SKU-1',7);
grant usage on schema public to cycle_app; grant select on public.remote_products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, sslmode ''disable'', channel_binding %L)', :'dbname', :'binding') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_loopback options (user 'postgres', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'remote_products');
grant select on public.products_remote to cycle_app;
SQL
}
setup_db "$SOURCE_ADMIN_URL" cycle_d_source disable
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination require
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
server_binding(){ psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='channel_binding';"; }
src_before="$(server_binding "$SOURCE_ADMIN_URL")"; dst_before="$(server_binding "$DESTINATION_ADMIN_URL")"
set +e; sr="$(psql "$SOURCE_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products_remote order by id;' 2>&1)"; src_app_exit=$?; dr="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products_remote order by id;' 2>&1)"; dst_app_exit=$?; set -e
printf 'BEFORE\nsource foreign server channel_binding=%s\ndestination foreign server channel_binding=%s\nsource app exit=%s\nsource app=%s\ndestination app exit=%s\ndestination app=%s\n' "$src_before" "$dst_before" "$src_app_exit" "$sr" "$dst_app_exit" "$dr"
[[ "$src_before" == disable && "$dst_before" == require && "$src_app_exit" -eq 0 && "$sr" == '1|REMOTE-SKU-1|7' && "$dst_app_exit" -ne 0 ]] || { echo 'Fixture invalid' >&2; exit 2; }
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"
set +e; runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?; set -e; printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then printf 'NEON_FOREIGN_SERVER_CHANNEL_BINDING_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"; if grep -Eqi 'foreign server.*(channel_binding|channel binding|option|incompatib|drift|mismatch)|(channel_binding|channel binding|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then echo 'NEON_FOREIGN_SERVER_CHANNEL_BINDING_DRIFT_FAIL_CLOSED=true'; exit 0; fi; echo 'NEON_FOREIGN_SERVER_CHANNEL_BINDING_DRIFT_FAIL_CLOSED=false'; exit 1; fi
dst_after="$(server_binding "$DESTINATION_ADMIN_URL")"; row2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=2;')"
set +e; dr2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products_remote order by id;' 2>&1)"; dst_app_exit2=$?; set -e
printf 'AFTER\ndestination foreign server channel_binding=%s\nappended source row=%s\ndestination app exit=%s\ndestination app=%s\nNEON_FOREIGN_SERVER_CHANNEL_BINDING_DRIFT_SYNC_EXIT=%s\n' "$dst_after" "$row2" "$dst_app_exit2" "$dr2" "$sync_exit"
if [[ "$dst_after" == disable && "$row2" == '2|SOURCE-SKU-2|11' && "$dst_app_exit2" -eq 0 ]]; then echo 'NEON_FOREIGN_SERVER_CHANNEL_BINDING_DRIFT_DETECTED=true'; exit 0; fi
if [[ "$dst_after" == require && "$row2" == '2|SOURCE-SKU-2|11' && "$dst_app_exit2" -ne 0 ]]; then echo 'NEON_FOREIGN_SERVER_CHANNEL_BINDING_DRIFT_DETECTED=false'; echo 'NEON_FOREIGN_SERVER_CHANNEL_BINDING_APPLICATION_PATH_BROKEN=true'; exit 1; fi
echo 'Unexpected post-sync state' >&2; exit 2

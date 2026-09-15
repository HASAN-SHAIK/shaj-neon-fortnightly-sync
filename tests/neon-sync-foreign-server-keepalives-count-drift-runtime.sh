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
 local admin_url="$1" dbname="$2" count="$3"
 psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v count="$count" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create table public.remote_products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.remote_products values (1,'REMOTE-SKU-1',7);
grant usage on schema public to cycle_app; grant select,insert on public.remote_products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, keepalives_count %L)', :'dbname', :'count') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_loopback options (user 'postgres', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'remote_products');
grant select,insert on public.products_remote to cycle_app;
SQL
}
setup_db "$SOURCE_ADMIN_URL" cycle_d_source 2
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination 10
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
server_count(){ psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='keepalives_count';"; }
app_read(){ psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products_remote order by id;'; }
app_write_probe(){ local app="$1" admin="$2" id="$3"; psql "$app" -v ON_ERROR_STOP=1 -qAt <<SQL
begin; insert into public.products_remote values ($id,'PROBE-$id',3); select count(*) from public.products_remote where id=$id; rollback;
SQL
psql "$admin" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.remote_products where id=$id;"; }
src_before="$(server_count "$SOURCE_ADMIN_URL")"; dst_before="$(server_count "$DESTINATION_ADMIN_URL")"
sr="$(app_read "$SOURCE_APP_URL")"; dr="$(app_read "$DESTINATION_APP_URL")"; sw="$(app_write_probe "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" 9401)"; dw="$(app_write_probe "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" 9402)"
printf 'BEFORE\nsource foreign server keepalives_count=%s\ndestination foreign server keepalives_count=%s\nsource app read=%s\ndestination app read=%s\nsource write probe=%s\ndestination write probe=%s\n' "$src_before" "$dst_before" "$sr" "$dr" "$sw" "$dw"
[[ "$src_before" == 2 && "$dst_before" == 10 && "$sr" == '1|REMOTE-SKU-1|7' && "$dr" == '1|REMOTE-SKU-1|7' && "$sw" == $'1\n0' && "$dw" == $'1\n0' ]] || { echo 'Fixture invalid' >&2; exit 2; }
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"
set +e; runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?; set -e; printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then printf 'NEON_FOREIGN_SERVER_KEEPALIVES_COUNT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"; if grep -Eqi 'foreign server.*(keepalives_count|keepalive|option|incompatib|drift|mismatch)|(keepalives_count|keepalive|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then echo 'NEON_FOREIGN_SERVER_KEEPALIVES_COUNT_DRIFT_FAIL_CLOSED=true'; exit 0; fi; echo 'NEON_FOREIGN_SERVER_KEEPALIVES_COUNT_DRIFT_FAIL_CLOSED=false'; exit 1; fi
dst_after="$(server_count "$DESTINATION_ADMIN_URL")"; row2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=2;')"; sr2="$(app_read "$SOURCE_APP_URL")"; dr2="$(app_read "$DESTINATION_APP_URL")"; sw2="$(app_write_probe "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" 9411)"; dw2="$(app_write_probe "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" 9412)"
printf 'AFTER\ndestination foreign server keepalives_count=%s\nappended source row=%s\nsource app read=%s\ndestination app read=%s\nsource write probe=%s\ndestination write probe=%s\nNEON_FOREIGN_SERVER_KEEPALIVES_COUNT_DRIFT_SYNC_EXIT=%s\n' "$dst_after" "$row2" "$sr2" "$dr2" "$sw2" "$dw2" "$sync_exit"
if [[ "$dst_after" == 2 && "$row2" == '2|SOURCE-SKU-2|11' && "$sr2" == '1|REMOTE-SKU-1|7' && "$dr2" == '1|REMOTE-SKU-1|7' && "$sw2" == $'1\n0' && "$dw2" == $'1\n0' ]]; then echo 'NEON_FOREIGN_SERVER_KEEPALIVES_COUNT_DRIFT_DETECTED=true'; exit 0; fi
if [[ "$dst_after" == 10 && "$row2" == '2|SOURCE-SKU-2|11' && "$sr2" == '1|REMOTE-SKU-1|7' && "$dr2" == '1|REMOTE-SKU-1|7' && "$sw2" == $'1\n0' && "$dw2" == $'1\n0' ]]; then echo 'NEON_FOREIGN_SERVER_KEEPALIVES_COUNT_DRIFT_DETECTED=false'; echo 'NEON_FOREIGN_SERVER_KEEPALIVES_COUNT_POLICY_DIVERGENCE=true'; exit 1; fi
echo 'Unexpected post-sync state' >&2; exit 2

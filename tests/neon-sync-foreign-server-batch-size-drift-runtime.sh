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
  local admin_url="$1" dbname="$2" batch_size="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v batch_size="$batch_size" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select, insert, update, delete on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, batch_size %L)', :'dbname', :'batch_size') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'products');
grant select, insert, update, delete on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source 100
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination 1
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_batch_size() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='batch_size';"
}
app_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select count(*),coalesce(sum(quantity),0) from public.products_remote;"
}
write_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -qAt <<'SQL'
begin;
insert into public.products_remote(id,sku,quantity)
select 90000+g, 'BATCH-PROBE-'||g, g from generate_series(1,20) g;
select count(*) from public.products_remote where id between 90001 and 90020;
rollback;
select count(*) from public.products_remote where id between 90001 and 90020;
SQL
}

source_option_before="$(server_batch_size "$SOURCE_ADMIN_URL")"
destination_option_before="$(server_batch_size "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_read "$SOURCE_APP_URL")"
destination_read_before="$(app_read "$DESTINATION_APP_URL")"
source_write_before="$(write_probe "$SOURCE_APP_URL")"
destination_write_before="$(write_probe "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource foreign server batch_size=%s\ndestination foreign server batch_size=%s\n' "$source_option_before" "$destination_option_before"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_before" "$destination_read_before"
printf 'source batch write probe=%s\ndestination batch write probe=%s\n' "$source_write_before" "$destination_write_before"

if [[ "$source_option_before" != 100 || "$destination_option_before" != 1 || "$source_read_before" != '1|7' || "$destination_read_before" != '1|7' || "$source_write_before" != $'20\n0' || "$destination_write_before" != $'20\n0' ]]; then
  echo 'Fixture did not establish isolated foreign-server batch_size drift with a working real FDW write path.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_BATCH_SIZE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(batch_size|batch size|option|incompatib|drift|mismatch)|(batch_size|batch size|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_BATCH_SIZE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_BATCH_SIZE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_option_after="$(server_batch_size "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_read_after="$(app_read "$SOURCE_APP_URL")"
destination_read_after="$(app_read "$DESTINATION_APP_URL")"
source_write_after="$(write_probe "$SOURCE_APP_URL")"
destination_write_after="$(write_probe "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination foreign server batch_size=%s\nappended source row=%s\n' "$destination_option_after" "$destination_row_2"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_after" "$destination_read_after"
printf 'source batch write probe=%s\ndestination batch write probe=%s\n' "$source_write_after" "$destination_write_after"
printf 'NEON_FOREIGN_SERVER_BATCH_SIZE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_option_after" == 100 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' && "$source_write_after" == $'20\n0' && "$destination_write_after" == $'20\n0' ]]; then
  echo 'NEON_FOREIGN_SERVER_BATCH_SIZE_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_option_after" == 1 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' && "$source_write_after" == $'20\n0' && "$destination_write_after" == $'20\n0' ]]; then
  echo 'NEON_FOREIGN_SERVER_BATCH_SIZE_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_BATCH_SIZE_POLICY_DIVERGENCE=true'
  echo 'Destination retained server-level batch_size=1; production synchronization succeeded while the real application FDW read/write path remained functionally correct but used a different insert batching policy.' >&2
  exit 1
fi

echo 'Post-sync foreign-server batch_size scenario produced an unexpected runtime state.' >&2
exit 2

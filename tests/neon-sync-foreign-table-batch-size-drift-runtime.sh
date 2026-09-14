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
  local admin_url="$1" batch_size="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v batch_size="$batch_size" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select, insert on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L)', current_database()) \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
select format('create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name ''public'', table_name ''products'', batch_size %L)', :'batch_size') \gexec
grant select, insert on public.products_remote to cycle_app;
insert into public.products values (1,'BASE-SKU-1',7);
SQL
}

setup_db "$SOURCE_ADMIN_URL" 100
setup_db "$DESTINATION_ADMIN_URL" 1

table_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select ftoptions from pg_foreign_table where ftrelid='public.products_remote'::regclass)) where option_name='batch_size';"
}
server_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select coalesce((select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='batch_size'), '<absent>');"
}
app_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c 'select count(*), sum(quantity) from public.products_remote;'
}
write_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At <<'SQL'
begin;
insert into public.products_remote(id,sku,quantity)
select 1000 + g, 'PROBE-' || g::text, g from generate_series(1,20) g;
select count(*) from public.products_remote where id between 1001 and 1020;
rollback;
select count(*) from public.products_remote where id between 1001 and 1020;
SQL
}

source_before="$(table_option "$SOURCE_ADMIN_URL")"
destination_before="$(table_option "$DESTINATION_ADMIN_URL")"
source_server_before="$(server_option "$SOURCE_ADMIN_URL")"
destination_server_before="$(server_option "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_read "$SOURCE_APP_URL")"
destination_read_before="$(app_read "$DESTINATION_APP_URL")"
source_write_before="$(write_probe "$SOURCE_APP_URL" | tail -n 2 | paste -sd '|' -)"
destination_write_before="$(write_probe "$DESTINATION_APP_URL" | tail -n 2 | paste -sd '|' -)"

printf 'BEFORE\nsource table batch_size=%s\ndestination table batch_size=%s\nsource server batch_size=%s\ndestination server batch_size=%s\nsource app read=%s\ndestination app read=%s\nsource write probe=%s\ndestination write probe=%s\n' \
  "$source_before" "$destination_before" "$source_server_before" "$destination_server_before" "$source_read_before" "$destination_read_before" "$source_write_before" "$destination_write_before"

if [[ "$source_before" != 100 || "$destination_before" != 1 || "$source_server_before" != '<absent>' || "$destination_server_before" != '<absent>' || "$source_read_before" != '1|7' || "$destination_read_before" != '1|7' || "$source_write_before" != '20|0' || "$destination_write_before" != '20|0' ]]; then
  echo 'Fixture did not establish isolated foreign-table batch_size override drift with equivalent executable application paths.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_TABLE_BATCH_SIZE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign table.*batch_size|batch_size.*(drift|mismatch)' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_TABLE_BATCH_SIZE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_TABLE_BATCH_SIZE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_after="$(table_option "$DESTINATION_ADMIN_URL")"
destination_server_after="$(server_option "$DESTINATION_ADMIN_URL")"
source_read_after="$(app_read "$SOURCE_APP_URL")"
destination_read_after="$(app_read "$DESTINATION_APP_URL")"
source_write_after="$(write_probe "$SOURCE_APP_URL" | tail -n 2 | paste -sd '|' -)"
destination_write_after="$(write_probe "$DESTINATION_APP_URL" | tail -n 2 | paste -sd '|' -)"
destination_row="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

printf 'AFTER\ndestination table batch_size=%s\ndestination server batch_size=%s\nsource app read=%s\ndestination app read=%s\nsource write probe=%s\ndestination write probe=%s\nappended source row=%s\n' \
  "$destination_after" "$destination_server_after" "$source_read_after" "$destination_read_after" "$source_write_after" "$destination_write_after" "$destination_row"
printf 'NEON_FOREIGN_TABLE_BATCH_SIZE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_after" == 100 && "$destination_server_after" == '<absent>' && "$source_read_after" == "$destination_read_after" && "$source_write_after" == '20|0' && "$destination_write_after" == '20|0' && "$destination_row" == '2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_FOREIGN_TABLE_BATCH_SIZE_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_after" == 1 && "$destination_server_after" == '<absent>' && "$source_read_after" == "$destination_read_after" && "$source_write_after" == '20|0' && "$destination_write_after" == '20|0' && "$destination_row" == '2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_FOREIGN_TABLE_BATCH_SIZE_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_TABLE_BATCH_SIZE_OVERRIDE_DIVERGENCE=true'
  exit 1
fi

echo 'Post-sync foreign-table batch_size scenario produced an unexpected runtime state.' >&2
exit 2

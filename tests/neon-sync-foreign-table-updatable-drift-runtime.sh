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
  local admin_url="$1" dbname="$2" updatable="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v updatable="$updatable" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select, insert, update, delete on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L)', :'dbname') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
select format('create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name ''public'', table_name ''products'', updatable %L)', :'updatable') \gexec
grant select, insert, update, delete on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source true
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination false
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

updatable_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select ftoptions from pg_foreign_table where ftrelid='public.products_remote'::regclass)) where option_name='updatable';"
}
foreign_insert_probe() {
  local url="$1" id="$2" sku="$3"
  psql "$url" -v ON_ERROR_STOP=1 -At -F '|' <<SQL
begin;
insert into public.products_remote(id,sku,quantity) values ($id,'$sku',9) returning id,sku,quantity;
rollback;
SQL
}

source_option_before="$(updatable_option "$SOURCE_ADMIN_URL")"
destination_option_before="$(updatable_option "$DESTINATION_ADMIN_URL")"
source_read_before="$(psql "$SOURCE_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products_remote order by id;")"
destination_read_before="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products_remote order by id;")"
source_insert_before="$(foreign_insert_probe "$SOURCE_APP_URL" 90001 SOURCE-FDW-WRITE)"
set +e
destination_insert_before_output="$(foreign_insert_probe "$DESTINATION_APP_URL" 90001 DEST-FDW-WRITE 2>&1)"; destination_insert_before_exit=$?
set -e

printf 'BEFORE\nsource foreign table updatable=%s\ndestination foreign table updatable=%s\n' "$source_option_before" "$destination_option_before"
printf 'source read=%s\ndestination read=%s\n' "$source_read_before" "$destination_read_before"
printf 'source foreign insert probe=%s\n' "$source_insert_before"
printf 'destination foreign insert exit=%s\ndestination foreign insert output=%s\n' "$destination_insert_before_exit" "$destination_insert_before_output"

if [[ "$source_option_before" != true || "$destination_option_before" != false || "$source_read_before" != '1|BASE-SKU-1|7' || "$destination_read_before" != '1|BASE-SKU-1|7' || "$source_insert_before" != *'90001|SOURCE-FDW-WRITE|9'* || "$destination_insert_before_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated foreign-table updatable drift.' >&2
  exit 2
fi

if [[ "$(psql "$SOURCE_ADMIN_URL" -Atc "select count(*) from public.products where id=90001;")" != 0 || "$(psql "$DESTINATION_ADMIN_URL" -Atc "select count(*) from public.products where id=90001;")" != 0 ]]; then
  echo 'Rollback probe left unexpected data behind.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_TABLE_UPDATABLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign table.*(updatable|option|incompatib|drift|mismatch)|(updatable|option|drift|mismatch).*foreign table' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_TABLE_UPDATABLE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_TABLE_UPDATABLE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_option_after="$(updatable_option "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_insert_after="$(foreign_insert_probe "$SOURCE_APP_URL" 90002 SOURCE-FDW-WRITE-AFTER)"
set +e
destination_insert_after_output="$(foreign_insert_probe "$DESTINATION_APP_URL" 90002 DEST-FDW-WRITE-AFTER 2>&1)"; destination_insert_after_exit=$?
set -e

printf 'AFTER\ndestination foreign table updatable=%s\nappended source row=%s\n' "$destination_option_after" "$destination_row_2"
printf 'source foreign insert probe=%s\n' "$source_insert_after"
printf 'destination foreign insert exit=%s\ndestination foreign insert output=%s\n' "$destination_insert_after_exit" "$destination_insert_after_output"
printf 'NEON_FOREIGN_TABLE_UPDATABLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_option_after" == true && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_insert_after" == *'90002|SOURCE-FDW-WRITE-AFTER|9'* && "$destination_insert_after_exit" -eq 0 ]]; then
  echo 'NEON_FOREIGN_TABLE_UPDATABLE_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_option_after" == false && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_insert_after" == *'90002|SOURCE-FDW-WRITE-AFTER|9'* && "$destination_insert_after_exit" -ne 0 ]]; then
  echo 'NEON_FOREIGN_TABLE_UPDATABLE_DRIFT_DETECTED=false'
  echo 'Destination retained updatable=false; production synchronization succeeded while the real application foreign-table write path remained unavailable.' >&2
  exit 1
fi

echo 'Post-sync foreign-table updatable scenario produced an unexpected runtime state.' >&2
exit 2

#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

setup_db() {
  local admin_url="$1" dbname="$2" mapped_user="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v mapped_user="$mapped_user" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L)', :'dbname') \gexec
select format('create user mapping for cycle_app server retail_loopback options (user %L, password_required ''false'')', :'mapped_user') \gexec
create foreign table public.products_remote(id bigint, sku text, quantity integer)
  server retail_loopback options (schema_name 'public', table_name 'products');
grant select on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source cycle_app
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination cycle_other
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

mapping_user() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select umoptions from pg_user_mappings where srvname='retail_loopback' and usename='cycle_app')) where option_name='user';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products_remote order by id;"
}

source_mapping_before="$(mapping_user "$SOURCE_ADMIN_URL")"
destination_mapping_before="$(mapping_user "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
set +e
destination_app_before_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_before_exit=$?
set -e

printf 'BEFORE\nsource user mapping remote user=%s\ndestination user mapping remote user=%s\n' "$source_mapping_before" "$destination_mapping_before"
printf 'source app foreign probe=%s\n' "$source_app_before"
printf 'destination app foreign probe exit=%s\ndestination app foreign probe output=%s\n' "$destination_app_before_exit" "$destination_app_before_output"

if [[ "$source_mapping_before" != cycle_app || "$destination_mapping_before" != cycle_other || "$source_app_before" != '1|BASE-SKU-1|7' || "$destination_app_before_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated FDW user-mapping option drift.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_USER_MAPPING_OPTION_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'user mapping.*(option|incompatib|drift|mismatch)|(option|drift|mismatch).*user mapping' <<<"$runtime_output"; then
    echo 'NEON_USER_MAPPING_OPTION_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_USER_MAPPING_OPTION_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_mapping_after="$(mapping_user "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_app_after_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_exit=$?
set -e

printf 'AFTER\ndestination user mapping remote user=%s\nappended source row=%s\n' "$destination_mapping_after" "$destination_row_2"
printf 'destination app foreign probe exit=%s\ndestination app foreign probe output=%s\n' "$destination_app_after_exit" "$destination_app_after_output"
printf 'NEON_USER_MAPPING_OPTION_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_mapping_after" == cycle_app && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_app_after_exit" -eq 0 && "$destination_app_after_output" == $'1|BASE-SKU-1|7\n2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_USER_MAPPING_OPTION_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_mapping_after" == cycle_other && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_app_after_exit" -ne 0 ]]; then
  echo 'NEON_USER_MAPPING_OPTION_DRIFT_DETECTED=false'
  echo 'Destination retained an incompatible FDW user mapping; production synchronization succeeded while the real application foreign-table path remained broken.' >&2
  exit 1
fi

echo 'Post-sync FDW user-mapping scenario produced an unexpected runtime state.' >&2
exit 2

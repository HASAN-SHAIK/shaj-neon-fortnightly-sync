#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
done

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source owner cycle_owner;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination owner cycle_other;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
grant usage on schema public to cycle_app, cycle_other;
grant select, insert on public.products to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
grant usage on schema public to cycle_app, cycle_other;
grant select, insert on public.products to cycle_app;
SQL

owner_of_database() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(datdba) from pg_database where datname=current_database();"
}
set_read_only_as_other() {
  local url="$1"
  local db="$2"
  psql "$url" -v ON_ERROR_STOP=1 -c "alter database \"$db\" set default_transaction_read_only = on;"
}
reset_read_only_as_other() {
  local url="$1"
  local db="$2"
  psql "$url" -v ON_ERROR_STOP=1 -c "alter database \"$db\" reset default_transaction_read_only;"
}

source_owner_before="$(owner_of_database "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_database "$DESTINATION_ADMIN_URL")"

set +e
source_set_output="$(set_read_only_as_other "$SOURCE_OTHER_URL" cycle_d_source 2>&1)"; source_set_exit=$?
destination_set_output="$(set_read_only_as_other "$DESTINATION_OTHER_URL" cycle_d_destination 2>&1)"; destination_set_exit=$?
set -e

printf 'BEFORE\nsource database owner=%s\ndestination database owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source cycle_other ALTER DATABASE SET exit=%s\nsource cycle_other output=%s\n' "$source_set_exit" "$source_set_output"
printf 'destination cycle_other ALTER DATABASE SET exit=%s\ndestination cycle_other output=%s\n' "$destination_set_exit" "$destination_set_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_set_exit" -eq 0 || "$destination_set_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated database ownership drift.' >&2
  exit 2
fi

# Restore destination database configuration before production synchronization while preserving owner drift.
reset_read_only_as_other "$DESTINATION_OTHER_URL" cycle_d_destination
pre_sync_read_only="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -Atc 'show default_transaction_read_only;')"
if [[ "$pre_sync_read_only" != off ]]; then
  echo "Destination read-only setting did not restore before sync: $pre_sync_read_only" >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_DATABASE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'database.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*database.*(incompatib|drift|mismatch)' <<<"$runtime_output"; then
    echo 'NEON_DATABASE_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_DATABASE_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_database "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_set_after_output="$(set_read_only_as_other "$DESTINATION_OTHER_URL" cycle_d_destination 2>&1)"; destination_set_after_exit=$?
set -e

destination_app_read_only="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -Atc 'show default_transaction_read_only;')"
set +e
destination_app_insert_output="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (900,'AFTER-OWNER-PROBE',1);" 2>&1)"; destination_app_insert_exit=$?
set -e

printf 'AFTER\ndestination database owner=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_row_2"
printf 'destination cycle_other ALTER DATABASE SET exit=%s\ndestination cycle_other output=%s\n' "$destination_set_after_exit" "$destination_set_after_output"
printf 'destination cycle_app default_transaction_read_only=%s\n' "$destination_app_read_only"
printf 'destination cycle_app insert exit=%s\ndestination cycle_app insert output=%s\n' "$destination_app_insert_exit" "$destination_app_insert_output"
printf 'NEON_DATABASE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_set_after_exit" -ne 0 && "$destination_app_read_only" == off && "$destination_app_insert_exit" -eq 0 ]]; then
  echo 'NEON_DATABASE_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_DATABASE_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained database-owner authority that source assigns to a different owner.' >&2
exit 1

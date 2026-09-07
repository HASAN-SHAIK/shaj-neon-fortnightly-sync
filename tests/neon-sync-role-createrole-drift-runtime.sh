#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'app' nocreaterole;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'app' createrole;
create database cycle_d_destination;
SQL

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
SQL
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
SQL

role_createrole() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolcreaterole from pg_roles where rolname='cycle_app';"
}
create_probe_role() {
  psql "$1" -v ON_ERROR_STOP=1 -c "create role cycle_created_probe;"
}
probe_role_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_roles where rolname='cycle_created_probe';"
}

source_attr_before="$(role_createrole "$SOURCE_ADMIN_URL")"
destination_attr_before="$(role_createrole "$DESTINATION_ADMIN_URL")"
set +e
source_create_output="$(create_probe_role "$SOURCE_APP_URL" 2>&1)"; source_create_exit=$?
destination_create_output="$(create_probe_role "$DESTINATION_APP_URL" 2>&1)"; destination_create_exit=$?
set -e

printf 'BEFORE\nsource cycle_app rolcreaterole=%s\ndestination cycle_app rolcreaterole=%s\n' "$source_attr_before" "$destination_attr_before"
printf 'source cycle_app CREATE ROLE exit=%s\nsource output=%s\n' "$source_create_exit" "$source_create_output"
printf 'destination cycle_app CREATE ROLE exit=%s\ndestination output=%s\n' "$destination_create_exit" "$destination_create_output"

if [[ "$source_attr_before" != f || "$destination_attr_before" != t || "$source_create_exit" -eq 0 || "$destination_create_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated CREATEROLE drift.' >&2
  exit 2
fi

# Remove the disposable destination probe before production synchronization.
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'drop role cycle_created_probe;'

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_CREATEROLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'createrole|role.*attribute.*(drift|mismatch|incompatib)' <<<"$runtime_output"; then
    echo 'NEON_ROLE_CREATEROLE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_CREATEROLE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_attr_after="$(role_createrole "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_create_after_output="$(create_probe_role "$DESTINATION_APP_URL" 2>&1)"; destination_create_after_exit=$?
set -e
destination_probe_count="$(probe_role_count "$DESTINATION_ADMIN_URL")"

printf 'AFTER\ndestination cycle_app rolcreaterole=%s\nappended source row=%s\n' "$destination_attr_after" "$destination_row_2"
printf 'destination cycle_app CREATE ROLE exit=%s\ndestination output=%s\ndestination probe role count=%s\n' "$destination_create_after_exit" "$destination_create_after_output" "$destination_probe_count"
printf 'NEON_ROLE_CREATEROLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_attr_after" == f && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_create_after_exit" -ne 0 && "$destination_probe_count" == 0 ]]; then
  echo 'NEON_ROLE_CREATEROLE_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_CREATEROLE_DRIFT_DETECTED=false'
echo 'Destination retained CREATEROLE authority that source denies.' >&2
exit 1

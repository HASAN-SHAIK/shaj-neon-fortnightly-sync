#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_ROOT_URL='postgresql://cycle_app:app@127.0.0.1:55432/postgres'
DESTINATION_APP_ROOT_URL='postgresql://cycle_app:app@127.0.0.1:55433/postgres'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' nocreatedb;"
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' createdb;"
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL

role_createdb() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolcreatedb from pg_roles where rolname='cycle_app';"
}
create_probe_db() {
  psql "$1" -v ON_ERROR_STOP=1 -c 'create database cycle_app_probe;'
}
probe_exists() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_database where datname='cycle_app_probe';"
}

source_createdb_before="$(role_createdb "$SOURCE_ROOT_URL")"
destination_createdb_before="$(role_createdb "$DESTINATION_ROOT_URL")"
set +e
source_create_output="$(create_probe_db "$SOURCE_APP_ROOT_URL" 2>&1)"; source_create_exit=$?
destination_create_output="$(create_probe_db "$DESTINATION_APP_ROOT_URL" 2>&1)"; destination_create_exit=$?
set -e

printf 'BEFORE\nsource cycle_app rolcreatedb=%s\ndestination cycle_app rolcreatedb=%s\n' "$source_createdb_before" "$destination_createdb_before"
printf 'source cycle_app CREATE DATABASE exit=%s\nsource output=%s\n' "$source_create_exit" "$source_create_output"
printf 'destination cycle_app CREATE DATABASE exit=%s\ndestination output=%s\n' "$destination_create_exit" "$destination_create_output"

if [[ "$source_createdb_before" != f || "$destination_createdb_before" != t || "$source_create_exit" -eq 0 || "$destination_create_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated CREATEDB role-attribute drift.' >&2
  exit 2
fi

# Remove the successful disposable destination probe before production synchronization.
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'drop database cycle_app_probe;'

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_CREATEDB_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'createdb|role.*attribute.*(incompatib|drift|mismatch)|(incompatib|drift|mismatch).*createdb' <<<"$runtime_output"; then
    echo 'NEON_ROLE_CREATEDB_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_CREATEDB_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_createdb_after="$(role_createdb "$DESTINATION_ROOT_URL")"
appended_source_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_create_after_output="$(create_probe_db "$DESTINATION_APP_ROOT_URL" 2>&1)"; destination_create_after_exit=$?
set -e
destination_probe_after="$(probe_exists "$DESTINATION_ROOT_URL")"

printf 'AFTER\ndestination cycle_app rolcreatedb=%s\nappended source row=%s\n' "$destination_createdb_after" "$appended_source_row"
printf 'destination cycle_app CREATE DATABASE exit=%s\ndestination output=%s\ndestination probe database count=%s\n' "$destination_create_after_exit" "$destination_create_after_output" "$destination_probe_after"
printf 'NEON_ROLE_CREATEDB_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_createdb_after" == f && "$appended_source_row" == '2|SOURCE-SKU-2|11' && "$destination_create_after_exit" -ne 0 && "$destination_probe_after" == 0 ]]; then
  echo 'NEON_ROLE_CREATEDB_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_CREATEDB_DRIFT_DETECTED=false'
echo 'Destination retained CREATEDB authority that source denies.' >&2
exit 1

#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OWNER_URL='postgresql://cycle_owner:cycle@127.0.0.1:55432/cycle_d_source'
DESTINATION_OWNER_URL='postgresql://cycle_owner:cycle@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_source owner cycle_owner;"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_destination owner cycle_owner;"

# Isolate database CREATE itself. cycle_other can connect to both databases,
# but only destination grants persistent namespace-creation authority.
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "grant connect on database cycle_d_source to cycle_other; revoke create on database cycle_d_source from cycle_other;"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "grant connect on database cycle_d_destination to cycle_other; grant create on database cycle_d_destination to cycle_other;"

psql "$SOURCE_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
SQL

has_database_create() {
  local url="$1"
  local db="$2"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select has_database_privilege('cycle_other','$db','CREATE');"
}

source_create_before="$(has_database_create "$SOURCE_POSTGRES_URL" cycle_d_source)"
destination_create_before="$(has_database_create "$DESTINATION_POSTGRES_URL" cycle_d_destination)"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -c 'create schema cycle_other_probe_before;' 2>&1)"
source_before_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c 'create schema cycle_other_probe_before;' 2>&1)"
destination_before_exit=$?
set -e

printf 'BEFORE\n'
printf 'source database CREATE privilege=%s\n' "$source_create_before"
printf 'destination database CREATE privilege=%s\n' "$destination_create_before"
printf 'source CREATE SCHEMA exit=%s\n' "$source_before_exit"
printf 'source CREATE SCHEMA output=%s\n' "$source_before_output"
printf 'destination CREATE SCHEMA exit=%s\n' "$destination_before_exit"
printf 'destination CREATE SCHEMA output=%s\n' "$destination_before_output"

if [[ "$source_create_before" != "f" || "$destination_create_before" != "t" || "$source_before_exit" -eq 0 || "$destination_before_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated database CREATE privilege drift.' >&2
  exit 2
fi

# Remove the successful destination probe so object shape is comparable before sync.
psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -c 'drop schema cycle_other_probe_before;'

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

# Explicit fail-closed handling of database CREATE incompatibility is safe.
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_DATABASE_CREATE_ACL_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi '(database|CREATE).*(ACL|privilege|permission|incompatib|drift)|(ACL|privilege|permission|incompatib|drift).*(database|CREATE)' <<<"$runtime_output"; then
    echo 'NEON_DATABASE_CREATE_ACL_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_DATABASE_CREATE_ACL_FAIL_CLOSED=false'
  echo 'Production sync failed for a reason not identified as this ACL incompatibility.' >&2
  exit 1
fi

destination_create_after="$(has_database_create "$DESTINATION_POSTGRES_URL" cycle_d_destination)"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c 'create schema cycle_other_probe_after;' 2>&1)"
destination_after_exit=$?
set -e

destination_probe_exists="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_namespace where nspname='cycle_other_probe_after';")"

printf 'AFTER\n'
printf 'destination database CREATE privilege=%s\n' "$destination_create_after"
printf 'appended source row=%s\n' "$destination_source_row_2"
printf 'destination CREATE SCHEMA exit=%s\n' "$destination_after_exit"
printf 'destination CREATE SCHEMA output=%s\n' "$destination_after_output"
printf 'destination probe schema exists=%s\n' "$destination_probe_exists"
printf 'NEON_DATABASE_CREATE_ACL_SYNC_EXIT=%s\n' "$sync_exit"

# Safe convergence requires destination to deny the same persistent namespace
# creation that source denies while still completing the legitimate row append.
if [[ "$destination_create_after" == "f" && "$destination_after_exit" -ne 0 && "$destination_probe_exists" == "0" && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_DATABASE_CREATE_ACL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_DATABASE_CREATE_ACL_DRIFT_DETECTED=false'
echo 'Destination retained database CREATE authority that source denies.' >&2
exit 1

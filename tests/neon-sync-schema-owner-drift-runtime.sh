#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_POSTGRES_URL="$SOURCE_ADMIN_URL"
DESTINATION_POSTGRES_URL="$DESTINATION_ADMIN_URL"
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
alter schema public owner to cycle_owner;
grant usage, create on schema public to cycle_other;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
alter schema public owner to cycle_other;
grant usage, create on schema public to cycle_other;
SQL

owner_of_schema() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(nspowner) from pg_namespace where nspname='public';"
}
rename_schema_as_other() {
  local url="$1"
  local target="$2"
  psql "$url" -v ON_ERROR_STOP=1 -c "alter schema public rename to ${target};"
}

source_owner_before="$(owner_of_schema "$SOURCE_POSTGRES_URL")"
destination_owner_before="$(owner_of_schema "$DESTINATION_POSTGRES_URL")"
source_other_usage_before="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_schema_privilege('cycle_other','public','USAGE');")"
destination_other_usage_before="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_schema_privilege('cycle_other','public','USAGE');")"
source_other_create_before="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_schema_privilege('cycle_other','public','CREATE');")"
destination_other_create_before="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_schema_privilege('cycle_other','public','CREATE');")"

set +e
source_rename_output="$(rename_schema_as_other "$SOURCE_OTHER_URL" 'cycle_other_probe_before' 2>&1)"
source_rename_exit=$?
set -e
set +e
destination_rename_output="$(rename_schema_as_other "$DESTINATION_OTHER_URL" 'cycle_other_probe_before' 2>&1)"
destination_rename_exit=$?
set -e

printf 'BEFORE\n'
printf 'source schema owner=%s\n' "$source_owner_before"
printf 'destination schema owner=%s\n' "$destination_owner_before"
printf 'source cycle_other USAGE=%s\n' "$source_other_usage_before"
printf 'destination cycle_other USAGE=%s\n' "$destination_other_usage_before"
printf 'source cycle_other CREATE=%s\n' "$source_other_create_before"
printf 'destination cycle_other CREATE=%s\n' "$destination_other_create_before"
printf 'source cycle_other rename exit=%s\n' "$source_rename_exit"
printf 'source cycle_other rename output=%s\n' "$source_rename_output"
printf 'destination cycle_other rename exit=%s\n' "$destination_rename_exit"
printf 'destination cycle_other rename output=%s\n' "$destination_rename_output"

if [[ "$source_owner_before" != 'cycle_owner' || "$destination_owner_before" != 'cycle_other' || "$source_other_usage_before" != 't' || "$destination_other_usage_before" != 't' || "$source_other_create_before" != 't' || "$destination_other_create_before" != 't' || "$source_rename_exit" -eq 0 || "$destination_rename_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated schema ownership drift.' >&2
  exit 2
fi

# Restore destination namespace identity before production synchronization while preserving ownership drift.
psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c 'alter schema cycle_other_probe_before rename to public;' >/dev/null
[[ "$(owner_of_schema "$DESTINATION_POSTGRES_URL")" == 'cycle_other' ]]

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_SCHEMA_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'schema.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*schema.*(incompatib|drift|mismatch)|(incompatib|drift|mismatch).*schema.*(owner|ownership)' <<<"$runtime_output"; then
    echo 'NEON_SCHEMA_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_SCHEMA_OWNER_DRIFT_FAIL_CLOSED=false'
  echo 'Production sync failed for a reason not identified as schema ownership incompatibility.' >&2
  exit 1
fi

destination_owner_after="$(owner_of_schema "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_rename_output="$(rename_schema_as_other "$DESTINATION_OTHER_URL" 'cycle_other_probe_after' 2>&1)"
destination_after_rename_exit=$?
set -e

printf 'AFTER\n'
printf 'destination schema owner=%s\n' "$destination_owner_after"
printf 'appended source row=%s\n' "$destination_source_row_2"
printf 'destination cycle_other rename exit=%s\n' "$destination_after_rename_exit"
printf 'destination cycle_other rename output=%s\n' "$destination_after_rename_output"
printf 'NEON_SCHEMA_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_owner_after" == 'cycle_owner' && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' && "$destination_after_rename_exit" -ne 0 ]]; then
  echo 'NEON_SCHEMA_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_SCHEMA_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained schema ownership authority that source assigns to a different role.' >&2
exit 1

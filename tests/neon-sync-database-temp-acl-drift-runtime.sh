#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_OWNER_URL='postgresql://cycle_owner:cycle@127.0.0.1:55432/cycle_d_source'
DESTINATION_OWNER_URL='postgresql://cycle_owner:cycle@127.0.0.1:55433/cycle_d_destination'
SOURCE_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_source owner cycle_owner;"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_destination owner cycle_owner;"

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "revoke temporary on database cycle_d_source from public;"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "revoke temporary on database cycle_d_destination from public; grant temporary on database cycle_d_destination to cycle_other;"

psql "$SOURCE_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
SQL

has_database_temp() {
  local url="$1"
  local db="$2"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select has_database_privilege('cycle_other','$db','TEMP');"
}

source_temp_before="$(has_database_temp "$SOURCE_POSTGRES_URL" cycle_d_source)"
destination_temp_before="$(has_database_temp "$DESTINATION_POSTGRES_URL" cycle_d_destination)"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -c "create temporary table cycle_other_temp_probe_before (id integer);" 2>&1)"
source_before_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c "create temporary table cycle_other_temp_probe_before (id integer);" 2>&1)"
destination_before_exit=$?
set -e

printf 'BEFORE\n'
printf 'source database TEMP privilege=%s\n' "$source_temp_before"
printf 'destination database TEMP privilege=%s\n' "$destination_temp_before"
printf 'source temp-table exit=%s\n' "$source_before_exit"
printf 'source temp-table output=%s\n' "$source_before_output"
printf 'destination temp-table exit=%s\n' "$destination_before_exit"
printf 'destination temp-table output=%s\n' "$destination_before_output"

if [[ "$source_temp_before" != "f" || "$destination_temp_before" != "t" || "$source_before_exit" -eq 0 || "$destination_before_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated database TEMP privilege drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

# An explicit fail-closed ACL incompatibility is acceptable only if production says why.
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_DATABASE_TEMP_ACL_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi '(database|TEMP|TEMPORARY).*(ACL|privilege|permission|incompatib|drift)|(ACL|privilege|permission|incompatib|drift).*(database|TEMP|TEMPORARY)' <<<"$runtime_output"; then
    echo 'NEON_DATABASE_TEMP_ACL_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_DATABASE_TEMP_ACL_FAIL_CLOSED=false'
  echo 'Production sync failed for a reason not identified as this ACL incompatibility.' >&2
  exit 1
fi

destination_temp_after="$(has_database_temp "$DESTINATION_POSTGRES_URL" cycle_d_destination)"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c "create temporary table cycle_other_temp_probe_after (id integer);" 2>&1)"
destination_after_exit=$?
set -e

printf 'AFTER\n'
printf 'destination database TEMP privilege=%s\n' "$destination_temp_after"
printf 'appended source row=%s\n' "$destination_source_row_2"
printf 'destination temp-table exit=%s\n' "$destination_after_exit"
printf 'destination temp-table output=%s\n' "$destination_after_output"
printf 'NEON_DATABASE_TEMP_ACL_SYNC_EXIT=%s\n' "$sync_exit"

# Safe convergence requires source semantics on destination plus successful data append.
if [[ "$destination_temp_after" == "f" && "$destination_after_exit" -ne 0 && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_DATABASE_TEMP_ACL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_DATABASE_TEMP_ACL_DRIFT_DETECTED=false'
echo 'Destination retained database TEMP authorization that source denies while production sync reported success.' >&2
exit 1

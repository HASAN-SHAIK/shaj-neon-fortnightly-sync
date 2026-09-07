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

psql "$SOURCE_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
revoke all on schema public from public;
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
grant select on table public.products to cycle_other;
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
revoke all on schema public from public;
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
grant select on table public.products to cycle_other;
grant usage on schema public to cycle_other;
SQL

has_schema_usage() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select has_schema_privilege('cycle_other','public','USAGE');"
}

source_usage_before="$(has_schema_usage "$SOURCE_POSTGRES_URL")"
destination_usage_before="$(has_schema_usage "$DESTINATION_POSTGRES_URL")"
source_table_select="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.products','SELECT');")"
destination_table_select="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.products','SELECT');")"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;" 2>&1)"
source_before_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;" 2>&1)"
destination_before_exit=$?
set -e

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_usage_after="$(has_schema_usage "$DESTINATION_POSTGRES_URL")"
destination_table_select_after="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.products','SELECT');")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;" 2>&1)"
destination_after_exit=$?
set -e

printf 'NEON_SCHEMA_ACL_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_SCHEMA_ACL_SOURCE_USAGE_BEFORE=%s\n' "$source_usage_before"
printf 'NEON_SCHEMA_ACL_DESTINATION_USAGE_BEFORE=%s\n' "$destination_usage_before"
printf 'NEON_SCHEMA_ACL_SOURCE_TABLE_SELECT=%s\n' "$source_table_select"
printf 'NEON_SCHEMA_ACL_DESTINATION_TABLE_SELECT=%s\n' "$destination_table_select"
printf 'NEON_SCHEMA_ACL_SOURCE_PROBE_EXIT=%s\n' "$source_before_exit"
printf 'NEON_SCHEMA_ACL_SOURCE_PROBE_OUTPUT=%s\n' "$source_before_output"
printf 'NEON_SCHEMA_ACL_DESTINATION_BEFORE_EXIT=%s\n' "$destination_before_exit"
printf 'NEON_SCHEMA_ACL_DESTINATION_BEFORE_OUTPUT=%s\n' "$destination_before_output"
printf 'NEON_SCHEMA_ACL_DESTINATION_USAGE_AFTER=%s\n' "$destination_usage_after"
printf 'NEON_SCHEMA_ACL_DESTINATION_TABLE_SELECT_AFTER=%s\n' "$destination_table_select_after"
printf 'NEON_SCHEMA_ACL_DESTINATION_AFTER_EXIT=%s\n' "$destination_after_exit"
printf 'NEON_SCHEMA_ACL_DESTINATION_AFTER_OUTPUT=%s\n' "$destination_after_output"
printf 'NEON_SCHEMA_ACL_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_usage_before" = 'f'
test "$destination_usage_before" = 't'
test "$source_table_select" = 't'
test "$destination_table_select" = 't'
test "$source_before_exit" -ne 0
grep -Eiq 'permission denied|schema|privilege' <<<"$source_before_output"
test "$destination_before_exit" -eq 0
test "$destination_before_output" = '1|SOURCE-SKU-1|7'

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'schema|usage|grant|privilege|acl|permission' <<<"$runtime_output"; then
    echo 'NEON_SCHEMA_ACL_DRIFT_SAFE_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'Production sync failed, but not for an explicit schema ACL/privilege incompatibility reason.' >&2
  exit 1
fi

test "$destination_source_row_2" = '2|SOURCE-SKU-2|11'
test "$destination_table_select_after" = 't'

if [[ "$destination_usage_after" = 'f' && "$destination_after_exit" -ne 0 ]] && \
   grep -Eiq 'permission denied|schema|privilege' <<<"$destination_after_output"; then
  echo 'NEON_SCHEMA_ACL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_SCHEMA_ACL_DRIFT_DETECTED=false'
echo 'Destination retained a source-absent schema USAGE privilege while production sync reported success.' >&2
exit 1

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
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
revoke all on public.products from public;
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
revoke all on public.products from public;
grant insert on public.products to cycle_other;
SQL

has_insert_privilege_for_other() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.products','INSERT');"
}

source_other_insert_before="$(has_insert_privilege_for_other "$SOURCE_POSTGRES_URL")"
destination_other_insert_before="$(has_insert_privilege_for_other "$DESTINATION_POSTGRES_URL")"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products values (901,'SOURCE-OTHER-FORBIDDEN',1) returning id,sku,quantity;" 2>&1)"
source_before_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products values (901,'DEST-OTHER-BEFORE',1) returning id,sku,quantity;" 2>&1)"
destination_before_exit=$?
set -e

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_other_insert_after="$(has_insert_privilege_for_other "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products values (902,'DEST-OTHER-AFTER',1) returning id,sku,quantity;" 2>&1)"
destination_after_exit=$?
set -e

printf 'NEON_TABLE_ACL_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_TABLE_ACL_SOURCE_OTHER_INSERT_BEFORE=%s\n' "$source_other_insert_before"
printf 'NEON_TABLE_ACL_DESTINATION_OTHER_INSERT_BEFORE=%s\n' "$destination_other_insert_before"
printf 'NEON_TABLE_ACL_DESTINATION_OTHER_INSERT_AFTER=%s\n' "$destination_other_insert_after"
printf 'NEON_TABLE_ACL_SOURCE_PROBE_EXIT=%s\n' "$source_before_exit"
printf 'NEON_TABLE_ACL_SOURCE_PROBE_OUTPUT=%s\n' "$source_before_output"
printf 'NEON_TABLE_ACL_DESTINATION_BEFORE_EXIT=%s\n' "$destination_before_exit"
printf 'NEON_TABLE_ACL_DESTINATION_BEFORE_OUTPUT=%s\n' "$destination_before_output"
printf 'NEON_TABLE_ACL_DESTINATION_AFTER_EXIT=%s\n' "$destination_after_exit"
printf 'NEON_TABLE_ACL_DESTINATION_AFTER_OUTPUT=%s\n' "$destination_after_output"
printf 'NEON_TABLE_ACL_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_other_insert_before" = 'f'
test "$destination_other_insert_before" = 't'
test "$source_before_exit" -ne 0
grep -Eiq 'permission denied|privilege' <<<"$source_before_output"
test "$destination_before_exit" -eq 0
grep -Fq '901|DEST-OTHER-BEFORE|1' <<<"$destination_before_output"

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'grant|privilege|acl|permission|products' <<<"$runtime_output"; then
    echo 'NEON_TABLE_ACL_DRIFT_SAFE_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'Production sync failed, but not for an explicit table ACL/privilege incompatibility reason.' >&2
  exit 1
fi

test "$destination_source_row_2" = '2|SOURCE-SKU-2|11'

if [[ "$destination_other_insert_after" = 'f' && "$destination_after_exit" -ne 0 ]] && \
   grep -Eiq 'permission denied|privilege' <<<"$destination_after_output"; then
  echo 'NEON_TABLE_ACL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_TABLE_ACL_DRIFT_DETECTED=false'
echo 'Destination retained a source-absent INSERT privilege while production sync reported success.' >&2
exit 1

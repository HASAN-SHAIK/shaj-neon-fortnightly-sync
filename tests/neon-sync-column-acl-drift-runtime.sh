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
grant select (id, sku, quantity) on public.products to cycle_other;
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
revoke all on public.products from public;
grant select (id, sku, quantity) on public.products to cycle_other;
grant update (quantity) on public.products to cycle_other;
SQL

has_quantity_update_privilege() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select has_column_privilege('cycle_other','public.products','quantity','UPDATE');"
}

has_sku_update_privilege() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select has_column_privilege('cycle_other','public.products','sku','UPDATE');"
}

has_table_update_privilege() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.products','UPDATE');"
}

source_quantity_update_before="$(has_quantity_update_privilege "$SOURCE_POSTGRES_URL")"
destination_quantity_update_before="$(has_quantity_update_privilege "$DESTINATION_POSTGRES_URL")"
destination_sku_update_before="$(has_sku_update_privilege "$DESTINATION_POSTGRES_URL")"
destination_table_update_before="$(has_table_update_privilege "$DESTINATION_POSTGRES_URL")"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "update public.products set quantity=8 where id=1;" 2>&1)"
source_before_exit=$?
set -e
source_before_row="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;")"

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "update public.products set quantity=8 where id=1;" 2>&1)"
destination_before_exit=$?
set -e
destination_before_row="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;")"

# Restore identical source/destination business state before invoking production sync.
psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 -c "update public.products set quantity=7 where id=1;"
destination_restored_row="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;")"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_quantity_update_after="$(has_quantity_update_privilege "$DESTINATION_POSTGRES_URL")"
destination_sku_update_after="$(has_sku_update_privilege "$DESTINATION_POSTGRES_URL")"
destination_table_update_after="$(has_table_update_privilege "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "update public.products set quantity=9 where id=1;" 2>&1)"
destination_after_exit=$?
set -e
destination_after_row="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;")"

printf 'NEON_COLUMN_ACL_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_COLUMN_ACL_SOURCE_QUANTITY_UPDATE_BEFORE=%s\n' "$source_quantity_update_before"
printf 'NEON_COLUMN_ACL_DESTINATION_QUANTITY_UPDATE_BEFORE=%s\n' "$destination_quantity_update_before"
printf 'NEON_COLUMN_ACL_DESTINATION_SKU_UPDATE_BEFORE=%s\n' "$destination_sku_update_before"
printf 'NEON_COLUMN_ACL_DESTINATION_TABLE_UPDATE_BEFORE=%s\n' "$destination_table_update_before"
printf 'NEON_COLUMN_ACL_SOURCE_PROBE_EXIT=%s\n' "$source_before_exit"
printf 'NEON_COLUMN_ACL_SOURCE_PROBE_OUTPUT=%s\n' "$source_before_output"
printf 'NEON_COLUMN_ACL_SOURCE_ROW_AFTER_PROBE=%s\n' "$source_before_row"
printf 'NEON_COLUMN_ACL_DESTINATION_BEFORE_EXIT=%s\n' "$destination_before_exit"
printf 'NEON_COLUMN_ACL_DESTINATION_BEFORE_OUTPUT=%s\n' "$destination_before_output"
printf 'NEON_COLUMN_ACL_DESTINATION_BEFORE_ROW=%s\n' "$destination_before_row"
printf 'NEON_COLUMN_ACL_DESTINATION_RESTORED_ROW=%s\n' "$destination_restored_row"
printf 'NEON_COLUMN_ACL_DESTINATION_QUANTITY_UPDATE_AFTER=%s\n' "$destination_quantity_update_after"
printf 'NEON_COLUMN_ACL_DESTINATION_SKU_UPDATE_AFTER=%s\n' "$destination_sku_update_after"
printf 'NEON_COLUMN_ACL_DESTINATION_TABLE_UPDATE_AFTER=%s\n' "$destination_table_update_after"
printf 'NEON_COLUMN_ACL_DESTINATION_AFTER_EXIT=%s\n' "$destination_after_exit"
printf 'NEON_COLUMN_ACL_DESTINATION_AFTER_OUTPUT=%s\n' "$destination_after_output"
printf 'NEON_COLUMN_ACL_DESTINATION_AFTER_ROW=%s\n' "$destination_after_row"
printf 'NEON_COLUMN_ACL_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_quantity_update_before" = 'f'
test "$destination_quantity_update_before" = 't'
test "$destination_sku_update_before" = 'f'
test "$destination_table_update_before" = 'f'
test "$source_before_exit" -ne 0
grep -Eiq 'permission denied|privilege' <<<"$source_before_output"
test "$source_before_row" = '1|SOURCE-SKU-1|7'
test "$destination_before_exit" -eq 0
test "$destination_before_row" = '1|SOURCE-SKU-1|8'
test "$destination_restored_row" = '1|SOURCE-SKU-1|7'

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'column|grant|privilege|acl|permission|products|quantity' <<<"$runtime_output"; then
    echo 'NEON_COLUMN_ACL_DRIFT_SAFE_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'Production sync failed, but not for an explicit column ACL/privilege incompatibility reason.' >&2
  exit 1
fi

test "$destination_source_row_2" = '2|SOURCE-SKU-2|11'
test "$destination_sku_update_after" = 'f'
test "$destination_table_update_after" = 'f'

if [[ "$destination_quantity_update_after" = 'f' && "$destination_after_exit" -ne 0 ]] && \
   grep -Eiq 'permission denied|privilege' <<<"$destination_after_output" && \
   [[ "$destination_after_row" = '1|SOURCE-SKU-1|7' ]]; then
  echo 'NEON_COLUMN_ACL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_COLUMN_ACL_DRIFT_DETECTED=false'
echo 'Destination retained a source-absent column UPDATE privilege while production sync reported success.' >&2
exit 1

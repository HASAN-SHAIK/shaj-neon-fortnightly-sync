#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7),
  (2, 'SOURCE-SKU-2', 11);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7),
  (900, null, 29);
SQL

source_notnull_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -Atc "select attnotnull from pg_attribute where attrelid = 'public.products'::regclass and attname = 'sku';")"
destination_notnull_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select attnotnull from pg_attribute where attrelid = 'public.products'::regclass and attname = 'sku';")"
destination_null_rows_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc 'select count(*) from public.products where sku is null;')"

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

destination_notnull_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select attnotnull from pg_attribute where attrelid = 'public.products'::regclass and attname = 'sku';")"
destination_null_rows_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc 'select count(*) from public.products where sku is null;')"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products where id = 2;')"
destination_rows_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, coalesce(sku, '<NULL>'), quantity from public.products order by id;")"

printf 'NEON_NOT_NULL_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_NOT_NULL_SOURCE_BEFORE=%s\n' "$source_notnull_before"
printf 'NEON_NOT_NULL_DESTINATION_BEFORE=%s\n' "$destination_notnull_before"
printf 'NEON_NOT_NULL_DESTINATION_AFTER=%s\n' "$destination_notnull_after"
printf 'NEON_NOT_NULL_DESTINATION_NULL_ROWS_BEFORE=%s\n' "$destination_null_rows_before"
printf 'NEON_NOT_NULL_DESTINATION_NULL_ROWS_AFTER=%s\n' "$destination_null_rows_after"
printf 'NEON_NOT_NULL_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_NOT_NULL_DESTINATION_ROWS_AFTER=%s\n' "${destination_rows_after//$'\n'/;}"

# Certification passes only if production either rejects the incompatible schema
# or leaves the destination with the same NOT NULL invariant as source.
if [[ "$sync_exit" -ne 0 ]]; then
  echo 'NEON_NOT_NULL_SCHEMA_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_notnull_after" == 't' && "$destination_null_rows_after" == '0' ]]; then
  echo 'NEON_NOT_NULL_SCHEMA_DRIFT_DETECTED=true'
  exit 0
fi

if ! grep -Fq 'Append sync and verification completed successfully for default.' <<<"$runtime_output"; then
  echo 'NEON_NOT_NULL_SCHEMA_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_NOT_NULL_SCHEMA_DRIFT_DETECTED=false' >&2
echo 'Production reported successful schema/data verification while destination sku remained nullable and retained a NULL row that source schema forbids.' >&2
exit 1

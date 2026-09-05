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
  sku text not null default 'SOURCE-DEFAULT',
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7),
  (2, 'SOURCE-SKU-2', 11);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null default 'DEST-DEFAULT',
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7);
SQL

source_default_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -Atc "select pg_get_expr(ad.adbin, ad.adrelid) from pg_attrdef ad join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum where ad.adrelid = 'public.products'::regclass and a.attname = 'sku';")"
destination_default_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select pg_get_expr(ad.adbin, ad.adrelid) from pg_attrdef ad join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum where ad.adrelid = 'public.products'::regclass and a.attname = 'sku';")"

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

destination_default_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select pg_get_expr(ad.adbin, ad.adrelid) from pg_attrdef ad join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum where ad.adrelid = 'public.products'::regclass and a.attname = 'sku';")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products where id = 2;')"

# Exercise the observable destination write semantics after sync. A promoted writable
# destination must generate the same omitted-column value as the source schema.
psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -c 'insert into public.products (id, quantity) values (900, 29);'
destination_default_probe="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products where id = 900;')"

printf 'NEON_DEFAULT_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_DEFAULT_SOURCE_BEFORE=%s\n' "$source_default_before"
printf 'NEON_DEFAULT_DESTINATION_BEFORE=%s\n' "$destination_default_before"
printf 'NEON_DEFAULT_DESTINATION_AFTER=%s\n' "$destination_default_after"
printf 'NEON_DEFAULT_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_DEFAULT_DESTINATION_PROBE=%s\n' "$destination_default_probe"

# Certification passes only if production rejects the incompatible schema or converges
# the destination default to the source default before reporting success.
if [[ "$sync_exit" -ne 0 ]]; then
  echo 'NEON_DEFAULT_SCHEMA_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_default_after" == "$source_default_before" && "$destination_default_probe" == '900|SOURCE-DEFAULT|29' ]]; then
  echo 'NEON_DEFAULT_SCHEMA_DRIFT_DETECTED=true'
  exit 0
fi

if ! grep -Fq 'Append sync and verification completed successfully for default.' <<<"$runtime_output"; then
  echo 'NEON_DEFAULT_SCHEMA_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_DEFAULT_SCHEMA_DRIFT_DETECTED=false' >&2
echo 'Production reported successful schema/data verification while destination retained a different column default and generated a divergent omitted-column value.' >&2
exit 1

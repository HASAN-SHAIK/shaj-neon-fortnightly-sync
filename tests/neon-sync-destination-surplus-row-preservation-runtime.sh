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
  sku text not null unique,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7),
  (2, 'SOURCE-SKU-2', 11);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null unique,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7),
  (900, 'DESTINATION-ONLY-SKU-900', 29);
SQL

source_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"
destination_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

source_after="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"
destination_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"
destination_count="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc 'select count(*) from public.products;')"
destination_only_count="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products where id = 900 and sku = 'DESTINATION-ONLY-SKU-900' and quantity = 29;")"
missing_source_row_count="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products where id = 2 and sku = 'SOURCE-SKU-2' and quantity = 11;")"

printf 'NEON_SURPLUS_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_SURPLUS_SOURCE_BEFORE=%s\n' "${source_before//$'\n'/;}"
printf 'NEON_SURPLUS_SOURCE_AFTER=%s\n' "${source_after//$'\n'/;}"
printf 'NEON_SURPLUS_DESTINATION_BEFORE=%s\n' "${destination_before//$'\n'/;}"
printf 'NEON_SURPLUS_DESTINATION_AFTER=%s\n' "${destination_after//$'\n'/;}"
printf 'NEON_SURPLUS_DESTINATION_ROWS=%s\n' "$destination_count"
printf 'NEON_SURPLUS_DESTINATION_ONLY_ROWS=%s\n' "$destination_only_count"
printf 'NEON_SURPLUS_MISSING_SOURCE_ROW_APPENDED=%s\n' "$missing_source_row_count"

expected_destination=$'1|SOURCE-SKU-1|7\n2|SOURCE-SKU-2|11\n900|DESTINATION-ONLY-SKU-900|29'

if [[ "$sync_exit" -ne 0 ]]; then
  echo "Production append sync did not complete successfully." >&2
  exit 1
fi
if [[ "$source_after" != "$source_before" ]]; then
  echo "Source state changed during one-way append sync." >&2
  exit 1
fi
if [[ "$destination_after" != "$expected_destination" ]]; then
  echo "Destination rows did not converge to source-plus-preserved-surplus state." >&2
  exit 1
fi
if [[ "$destination_count" != '3' || "$destination_only_count" != '1' || "$missing_source_row_count" != '1' ]]; then
  echo "Destination append/preservation counts are incorrect." >&2
  exit 1
fi
if ! grep -Fq 'Row count verification OK. Tables checked: 1.' <<<"$runtime_output"; then
  echo "Production row-count verification did not complete." >&2
  exit 1
fi
if ! grep -Fq 'Append sync and verification completed successfully for default.' <<<"$runtime_output"; then
  echo "Production sync completion marker is missing." >&2
  exit 1
fi

echo 'NEON_DESTINATION_SURPLUS_ROW_PRESERVATION_RUNTIME_PASS=true'

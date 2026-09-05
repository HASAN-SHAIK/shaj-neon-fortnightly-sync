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
  (1, 'DESTINATION-CONFLICT-1', 999),
  (2, 'SOURCE-SKU-2', 11);
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

destination_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"
source_conflicting_row="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products where id = 1;')"
destination_conflicting_row="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id, sku, quantity from public.products where id = 1;')"

printf 'NEON_CONFLICT_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_CONFLICT_SOURCE_BEFORE=%s\n' "${source_before//$'\n'/;}"
printf 'NEON_CONFLICT_DESTINATION_BEFORE=%s\n' "${destination_before//$'\n'/;}"
printf 'NEON_CONFLICT_DESTINATION_AFTER=%s\n' "${destination_after//$'\n'/;}"
printf 'NEON_CONFLICT_SOURCE_ROW=%s\n' "$source_conflicting_row"
printf 'NEON_CONFLICT_DESTINATION_ROW=%s\n' "$destination_conflicting_row"

if [[ "$source_conflicting_row" == "$destination_conflicting_row" ]]; then
  echo 'NEON_CONFLICTING_ROW_DIVERGENCE_DETECTED=true'
  exit 0
fi

if [[ "$sync_exit" -ne 0 ]]; then
  echo 'NEON_CONFLICTING_ROW_DIVERGENCE_DETECTED=true'
  exit 0
fi

if ! grep -Fq 'Append sync and verification completed successfully for default.' <<<"$runtime_output"; then
  echo 'NEON_CONFLICTING_ROW_DIVERGENCE_DETECTED=true'
  exit 0
fi

echo 'NEON_CONFLICTING_ROW_DIVERGENCE_DETECTED=false' >&2
echo 'Production reported successful verification while an existing destination row with the same primary key still differed from source.' >&2
exit 1

#!/usr/bin/env bash
set -Eeuo pipefail

: "${SOURCE_DATABASE_URL:?SOURCE_DATABASE_URL is required}"
: "${DESTINATION_DATABASE_URL:?DESTINATION_DATABASE_URL is required}"

source_count() {
  psql "$SOURCE_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products;"
}

destination_count() {
  psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products;"
}

assert_destination_state() {
  local phase="$1"
  local count
  local source_rows
  local destination_only

  count="$(destination_count)"
  source_rows="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select string_agg(id::text || ':' || sku || ':' || name, ',' order by id) from public.products where id in (1, 2);")"
  destination_only="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select sku || ':' || name from public.products where id = 99;")"

  if [[ "$count" != "3" ]]; then
    echo "$phase: expected exactly 3 destination rows, got $count" >&2
    exit 1
  fi

  if [[ "$source_rows" != "1:SKU-001:Tea,2:SKU-002:Coffee" ]]; then
    echo "$phase: source rows were not copied exactly: $source_rows" >&2
    exit 1
  fi

  if [[ "$destination_only" != "DEST-ONLY:Local retained row" ]]; then
    echo "$phase: destination-only row changed or disappeared: $destination_only" >&2
    exit 1
  fi

  echo "NEON_SYNC_${phase}_DESTINATION_COUNT=$count"
  echo "NEON_SYNC_${phase}_SOURCE_ROWS=$source_rows"
  echo "NEON_SYNC_${phase}_DESTINATION_ONLY=$destination_only"
}

if [[ "$(source_count)" != "2" ]]; then
  echo "fixture error: expected exactly two source rows" >&2
  exit 1
fi

before_destination_count="$(destination_count)"
if [[ "$before_destination_count" != "1" ]]; then
  echo "fixture error: expected one destination-only row before sync" >&2
  exit 1
fi

echo "NEON_SYNC_BEFORE_SOURCE_COUNT=2"
echo "NEON_SYNC_BEFORE_DESTINATION_COUNT=$before_destination_count"

bash scripts/neon-sync/append-sync.sh
assert_destination_state "FIRST_RUN"

bash scripts/neon-sync/append-sync.sh
assert_destination_state "SECOND_RUN"

echo "NEON_SYNC_RUNTIME_IDEMPOTENCY_PASS=true"

#!/usr/bin/env bash
set -Eeuo pipefail

: "${SOURCE_DATABASE_URL:?SOURCE_DATABASE_URL is required}"
: "${DESTINATION_DATABASE_URL:?DESTINATION_DATABASE_URL is required}"

assert_state() {
  local phase="$1"
  local product_rows
  local excluded_rows
  local excluded_count

  product_rows="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select string_agg(id::text || ':' || sku || ':' || name, ',' order by id) from public.products;")"
  excluded_rows="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select string_agg(id::text || ':' || note, ',' order by id) from public.audit_log;")"
  excluded_count="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.audit_log;")"

  if [[ "$product_rows" != "1:SKU-001:Tea,2:SKU-002:Coffee" ]]; then
    echo "$phase: non-excluded products did not synchronize exactly: $product_rows" >&2
    exit 1
  fi

  if [[ "$excluded_count" != "1" ]]; then
    echo "$phase: excluded audit_log gained or lost rows; expected 1, got $excluded_count" >&2
    exit 1
  fi

  if [[ "$excluded_rows" != "99:destination-retained" ]]; then
    echo "$phase: excluded audit_log destination data changed: $excluded_rows" >&2
    exit 1
  fi

  echo "NEON_EXCLUDED_${phase}_PRODUCTS=$product_rows"
  echo "NEON_EXCLUDED_${phase}_AUDIT_COUNT=$excluded_count"
  echo "NEON_EXCLUDED_${phase}_AUDIT_ROWS=$excluded_rows"
}

source_audit="$(psql "$SOURCE_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select string_agg(id::text || ':' || note, ',' order by id) from public.audit_log;")"
if [[ "$source_audit" != "1:source-secret-audit,2:source-second-audit" ]]; then
  echo "fixture error: unexpected source audit rows: $source_audit" >&2
  exit 1
fi

before_destination_audit="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select string_agg(id::text || ':' || note, ',' order by id) from public.audit_log;")"
if [[ "$before_destination_audit" != "99:destination-retained" ]]; then
  echo "fixture error: unexpected destination audit rows: $before_destination_audit" >&2
  exit 1
fi

echo "NEON_EXCLUDED_BEFORE_SOURCE_AUDIT=$source_audit"
echo "NEON_EXCLUDED_BEFORE_DESTINATION_AUDIT=$before_destination_audit"

bash scripts/neon-sync/append-sync.sh
assert_state "FIRST_RUN"

bash scripts/neon-sync/append-sync.sh
assert_state "SECOND_RUN"

echo "NEON_SYNC_EXCLUDED_TABLE_RUNTIME_PASS=true"

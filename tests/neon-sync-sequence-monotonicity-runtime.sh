#!/usr/bin/env bash
set -Eeuo pipefail

: "${SOURCE_DATABASE_URL:?SOURCE_DATABASE_URL is required}"
: "${DESTINATION_DATABASE_URL:?DESTINATION_DATABASE_URL is required}"

SCRIPT="scripts/neon-sync/append-sync.sh"

echo "NEON_SEQUENCE_RUNTIME_BEFORE_SOURCE=$(psql "$SOURCE_DATABASE_URL" -Atc "select last_value from public.products_id_seq")"
echo "NEON_SEQUENCE_RUNTIME_BEFORE_DESTINATION=$(psql "$DESTINATION_DATABASE_URL" -Atc "select last_value from public.products_id_seq")"
echo "NEON_SEQUENCE_RUNTIME_BEFORE_DESTINATION_MAX_ID=$(psql "$DESTINATION_DATABASE_URL" -Atc "select max(id) from public.products")"

bash "$SCRIPT"

source_last="$(psql "$SOURCE_DATABASE_URL" -Atc "select last_value from public.products_id_seq")"
destination_last="$(psql "$DESTINATION_DATABASE_URL" -Atc "select last_value from public.products_id_seq")"
destination_max="$(psql "$DESTINATION_DATABASE_URL" -Atc "select max(id) from public.products")"
row_count="$(psql "$DESTINATION_DATABASE_URL" -Atc "select count(*) from public.products")"

echo "NEON_SEQUENCE_RUNTIME_AFTER_SOURCE=$source_last"
echo "NEON_SEQUENCE_RUNTIME_AFTER_DESTINATION=$destination_last"
echo "NEON_SEQUENCE_RUNTIME_AFTER_DESTINATION_MAX_ID=$destination_max"
echo "NEON_SEQUENCE_RUNTIME_DESTINATION_ROWS=$row_count"

if [[ "$row_count" != "3" ]]; then
  echo "Expected three append-only destination rows after sync, got $row_count" >&2
  exit 1
fi

if (( destination_last < destination_max )); then
  echo "Sequence regression: destination sequence=$destination_last is behind destination max id=$destination_max" >&2
  exit 1
fi

new_id="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "insert into public.products (sku, name) values ('DEST-AFTER-SYNC', 'Destination write after sync') returning id")"
echo "NEON_SEQUENCE_RUNTIME_POST_SYNC_INSERT_ID=$new_id"

if (( new_id <= destination_max )); then
  echo "Post-sync default insert did not advance beyond existing destination identity space" >&2
  exit 1
fi

echo "NEON_SEQUENCE_MONOTONICITY_RUNTIME_PASS=true"

#!/usr/bin/env bash
set -Eeuo pipefail

: "${SOURCE_DATABASE_URL:?SOURCE_DATABASE_URL is required}"
: "${DESTINATION_DATABASE_URL:?DESTINATION_DATABASE_URL is required}"

SCRIPT="scripts/neon-sync/append-sync.sh"
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

before_count="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products")"
before_existing="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select name from public.products where sku='DEST-ONLY'")"
before_trigger="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select tgenabled from pg_trigger where tgname='products_audit_trigger'")"

echo "NEON_ATOMICITY_DESTINATION_ROWS_BEFORE=$before_count"
echo "NEON_ATOMICITY_EXISTING_ROW_BEFORE=$before_existing"
echo "NEON_ATOMICITY_TRIGGER_BEFORE=$before_trigger"

set +e
bash "$SCRIPT" >"$LOG_FILE" 2>&1
sync_status=$?
set -e

cat "$LOG_FILE"
echo "NEON_ATOMICITY_SYNC_EXIT=$sync_status"

if [[ "$sync_status" -eq 0 ]]; then
  echo "Expected append sync to fail on destination-only check constraint" >&2
  exit 1
fi

if ! grep -qiE 'check constraint|violates check constraint' "$LOG_FILE"; then
  echo "Expected runtime failure evidence from destination check constraint" >&2
  exit 1
fi

after_count="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products")"
after_existing="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select name from public.products where sku='DEST-ONLY'")"
source_rows_present="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products where sku in ('SRC-VALID','SRC-REJECT')")"
after_trigger="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select tgenabled from pg_trigger where tgname='products_audit_trigger'")"

echo "NEON_ATOMICITY_DESTINATION_ROWS_AFTER=$after_count"
echo "NEON_ATOMICITY_EXISTING_ROW_AFTER=$after_existing"
echo "NEON_ATOMICITY_SOURCE_ROWS_PRESENT_AFTER=$source_rows_present"
echo "NEON_ATOMICITY_TRIGGER_AFTER=$after_trigger"

if [[ "$after_count" != "$before_count" ]]; then
  echo "Destination row count changed despite failed transactional import" >&2
  exit 1
fi

if [[ "$after_existing" != "$before_existing" ]]; then
  echo "Pre-existing destination row changed during failed import" >&2
  exit 1
fi

if [[ "$source_rows_present" != "0" ]]; then
  echo "Partial source rows remained after failed import" >&2
  exit 1
fi

if [[ "$after_trigger" != "O" ]]; then
  echo "Destination user trigger was not restored to enabled state after rollback" >&2
  exit 1
fi

audit_before="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.product_audit")"
psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -c "insert into public.products (sku, name, quantity) values ('DEST-AFTER-FAILURE', 'Destination write after failure', 3);" >/dev/null
audit_after="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.product_audit")"

echo "NEON_ATOMICITY_AUDIT_BEFORE_POST_WRITE=$audit_before"
echo "NEON_ATOMICITY_AUDIT_AFTER_POST_WRITE=$audit_after"

if (( audit_after != audit_before + 1 )); then
  echo "User trigger did not fire after failed sync rollback" >&2
  exit 1
fi

echo "NEON_IMPORT_FAILURE_ATOMICITY_RUNTIME_PASS=true"

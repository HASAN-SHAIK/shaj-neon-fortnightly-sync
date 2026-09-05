#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="cycle_d_source"
SOURCE_ADMIN_URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres"
SOURCE_URL="postgresql://postgres:postgres@127.0.0.1:5432/${SOURCE_DB}"
DEST_URL="postgresql://postgres:postgres@127.0.0.1:65433/unreachable_destination?connect_timeout=2"
LOG_FILE="$(mktemp)"

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

createdb "$SOURCE_DB" --maintenance-db="$SOURCE_ADMIN_URL"
psql "$SOURCE_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.source_guard (
  id bigint primary key,
  value text not null
);
insert into public.source_guard (id, value) values (1, 'source-baseline');
SQL

rows_before="$(psql "$SOURCE_URL" -Atc 'select count(*) from public.source_guard;')"
value_before="$(psql "$SOURCE_URL" -Atc 'select value from public.source_guard where id = 1;')"

set +e
SOURCE_DATABASE_URL="$SOURCE_URL" \
DESTINATION_DATABASE_URL="$DEST_URL" \
NOTIFY_EMAIL_TO='' \
  bash "$ROOT_DIR/scripts/neon-sync/append-sync.sh" >"$LOG_FILE" 2>&1
sync_exit=$?
set -e

cat "$LOG_FILE"

rows_after="$(psql "$SOURCE_URL" -Atc 'select count(*) from public.source_guard;')"
value_after="$(psql "$SOURCE_URL" -Atc 'select value from public.source_guard where id = 1;')"

echo "NEON_DESTINATION_CONNECTION_FAILURE_EXIT=$sync_exit"
echo "NEON_DESTINATION_FAILURE_SOURCE_ROWS_BEFORE=$rows_before"
echo "NEON_DESTINATION_FAILURE_SOURCE_ROWS_AFTER=$rows_after"
echo "NEON_DESTINATION_FAILURE_SOURCE_VALUE_BEFORE=$value_before"
echo "NEON_DESTINATION_FAILURE_SOURCE_VALUE_AFTER=$value_after"

test "$sync_exit" -ne 0
grep -Fq 'Checking source connection for default...' "$LOG_FILE"
grep -Fq 'Checking destination connection for default...' "$LOG_FILE"
grep -Eq 'Connection refused|could not connect to server|connection to server .* failed' "$LOG_FILE"
! grep -Fq 'Dumping source schema for default...' "$LOG_FILE"
! grep -Fq 'Creating any missing schema objects on destination for default...' "$LOG_FILE"

test "$rows_before" = "1"
test "$rows_after" = "$rows_before"
test "$value_before" = 'source-baseline'
test "$value_after" = "$value_before"

echo 'NEON_DESTINATION_CONNECTION_FAILURE_RUNTIME_PASS=true'

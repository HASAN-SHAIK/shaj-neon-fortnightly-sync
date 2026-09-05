#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

log="$(mktemp)"
status=0

set +e
SOURCE_DATABASE_URL='psql postgresql://example.invalid/source' \
DESTINATION_DATABASE_URL='postgresql://example.invalid/destination' \
NOTIFY_EMAIL_TO='' \
bash scripts/neon-sync/append-sync.sh >"$log" 2>&1
status=$?
set -e

cat "$log"

echo "NEON_INVALID_URL_EXIT=$status"

if [[ "$status" -ne 2 ]]; then
  echo "Expected invalid database URL to exit 2, got $status" >&2
  exit 1
fi

if ! grep -Fq 'SOURCE_DATABASE_URL must be only the postgresql:// connection URL, not a full psql command.' "$log"; then
  echo "Expected fail-closed validation message was not emitted" >&2
  exit 1
fi

if grep -Fq 'Checking source connection' "$log"; then
  echo "Invalid URL progressed to a database connection attempt" >&2
  exit 1
fi

if grep -Fq 'Dumping source schema' "$log"; then
  echo "Invalid URL progressed to schema/data work" >&2
  exit 1
fi

echo 'NEON_INVALID_DATABASE_URL_RUNTIME_PASS=true'

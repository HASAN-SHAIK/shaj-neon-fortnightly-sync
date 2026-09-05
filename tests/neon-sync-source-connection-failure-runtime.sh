#!/usr/bin/env bash
set -Eeuo pipefail

DESTINATION_DATABASE_URL="${DESTINATION_DATABASE_URL:?DESTINATION_DATABASE_URL is required}"
SOURCE_DATABASE_URL="${SOURCE_DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:65432/unreachable_source?connect_timeout=2}"

psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table if not exists public.cycle_d_source_failure_probe (
  id integer primary key,
  value text not null
);
truncate table public.cycle_d_source_failure_probe;
insert into public.cycle_d_source_failure_probe (id, value) values (1, 'destination-baseline');
SQL

before_count="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc 'select count(*) from public.cycle_d_source_failure_probe;')"
before_value="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc 'select value from public.cycle_d_source_failure_probe where id = 1;')"

set +e
output="$(
  SOURCE_DATABASE_URL="$SOURCE_DATABASE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_DATABASE_URL" \
  EXCLUDED_TABLES='' \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
exit_code=$?
set -e

printf '%s\n' "$output"
echo "NEON_SOURCE_CONNECTION_FAILURE_EXIT=$exit_code"

if [[ "$exit_code" -eq 0 ]]; then
  echo "Expected source connection failure to return non-zero." >&2
  exit 1
fi

if ! grep -Fq 'Checking source connection for default...' <<<"$output"; then
  echo "Production sync did not reach the source connection check." >&2
  exit 1
fi

if grep -Fq 'Checking destination connection for default...' <<<"$output"; then
  echo "Destination connection was attempted after source connection failure." >&2
  exit 1
fi

if grep -Fq 'Dumping source schema for default...' <<<"$output"; then
  echo "Schema dump began after source connection failure." >&2
  exit 1
fi

after_count="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc 'select count(*) from public.cycle_d_source_failure_probe;')"
after_value="$(psql "$DESTINATION_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc 'select value from public.cycle_d_source_failure_probe where id = 1;')"

echo "NEON_SOURCE_FAILURE_DESTINATION_ROWS_BEFORE=$before_count"
echo "NEON_SOURCE_FAILURE_DESTINATION_ROWS_AFTER=$after_count"
echo "NEON_SOURCE_FAILURE_DESTINATION_VALUE_BEFORE=$before_value"
echo "NEON_SOURCE_FAILURE_DESTINATION_VALUE_AFTER=$after_value"

if [[ "$before_count" != "$after_count" || "$before_value" != "$after_value" ]]; then
  echo "Destination state changed despite source connection failure." >&2
  exit 1
fi

echo "NEON_SOURCE_CONNECTION_FAILURE_RUNTIME_PASS=true"

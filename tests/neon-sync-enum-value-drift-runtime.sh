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
create type public.order_status as enum ('NEW', 'PAID');
create table public.orders (
  id bigint primary key,
  status public.order_status not null
);
insert into public.orders (id, status) values
  (1, 'NEW'),
  (2, 'PAID');
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create type public.order_status as enum ('NEW', 'PAID', 'CANCELLED_INTERNAL');
create table public.orders (
  id bigint primary key,
  status public.order_status not null
);
insert into public.orders (id, status) values
  (1, 'NEW');
SQL

read_enum_values() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -At -F '|' -c "
    select e.enumlabel
    from pg_type t
    join pg_namespace n on n.oid=t.typnamespace
    join pg_enum e on e.enumtypid=t.oid
    where n.nspname='public' and t.typname='order_status'
    order by e.enumsortorder;" | paste -sd ',' -
}

source_enum_before="$(read_enum_values "$SOURCE_URL")"
destination_enum_before="$(read_enum_values "$DESTINATION_URL")"

# Prove the source database itself rejects the destination-only enum value.
set +e
source_probe_output="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.orders (id, status) values (900, 'CANCELLED_INTERNAL');" 2>&1)"
source_probe_exit=$?
set -e

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

destination_enum_after="$(read_enum_values "$DESTINATION_URL")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, status from public.orders where id=2;")"

# Exercise the real writable-destination semantics after production certification.
set +e
destination_probe_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.orders (id, status) values (900, 'CANCELLED_INTERNAL'); select id, status from public.orders where id=900;" 2>&1)"
destination_probe_exit=$?
set -e

printf 'NEON_ENUM_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_ENUM_SOURCE_BEFORE=%s\n' "$source_enum_before"
printf 'NEON_ENUM_DESTINATION_BEFORE=%s\n' "$destination_enum_before"
printf 'NEON_ENUM_SOURCE_PROBE_EXIT=%s\n' "$source_probe_exit"
printf 'NEON_ENUM_SOURCE_PROBE_OUTPUT=%s\n' "$source_probe_output"
printf 'NEON_ENUM_DESTINATION_AFTER=%s\n' "$destination_enum_after"
printf 'NEON_ENUM_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_ENUM_DESTINATION_PROBE_EXIT=%s\n' "$destination_probe_exit"
printf 'NEON_ENUM_DESTINATION_PROBE_OUTPUT=%s\n' "$destination_probe_output"

# Exact fixture preconditions and source behavior.
test "$source_enum_before" = 'NEW,PAID'
test "$destination_enum_before" = 'NEW,PAID,CANCELLED_INTERNAL'
test "$source_probe_exit" -ne 0
grep -Eiq 'invalid input value for enum|order_status' <<<"$source_probe_output"

# A non-zero production sync is safe only if it explicitly identifies the enum/type incompatibility.
if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'enum|order_status|type.*incompat|incompat.*type' <<<"$runtime_output"; then
    echo 'NEON_ENUM_VALUE_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_ENUM_VALUE_DRIFT_DETECTED=unverified' >&2
  echo 'Production failed for a reason not demonstrated to be enum-value incompatibility.' >&2
  exit 1
fi

# If production reports success, destination enum semantics must exactly match source semantics,
# the missing source row must exist, and the source-forbidden extra value must also be rejected.
if [[ "$destination_enum_after" = 'NEW,PAID' \
      && "$destination_source_row_2" = '2|PAID' \
      && "$destination_probe_exit" -ne 0 \
      && "$destination_probe_output" == *'invalid input value for enum'* \
      && "$runtime_output" == *'Append sync and verification completed successfully for default.'* \
      && "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_ENUM_VALUE_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ENUM_VALUE_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without preserving the source enum value set on the writable destination.' >&2
exit 1

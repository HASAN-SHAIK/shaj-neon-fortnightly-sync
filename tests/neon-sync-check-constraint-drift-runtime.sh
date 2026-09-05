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
  sku text not null,
  quantity integer not null,
  constraint products_quantity_nonnegative check (quantity >= 0)
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7),
  (2, 'SOURCE-SKU-2', 11);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (1, 'SOURCE-SKU-1', 7);
SQL

source_check_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='c' and conname='products_quantity_nonnegative';")"
destination_check_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='c' and conname='products_quantity_nonnegative';")"

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

destination_check_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='c' and conname='products_quantity_nonnegative';")"
destination_check_def_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.products'::regclass and contype='c' and conname='products_quantity_nonnegative';")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, sku, quantity from public.products where id=2;")"

# Exercise destination write semantics after sync. A negative quantity must be rejected
# if the source CHECK invariant has been converged before production reports success.
set +e
probe_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products (id, sku, quantity) values (900, 'NEGATIVE-SKU-900', -1); select id, sku, quantity from public.products where id=900;" 2>&1)"
probe_exit=$?
set -e

printf 'NEON_CHECK_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_CHECK_SOURCE_BEFORE=%s\n' "$source_check_before"
printf 'NEON_CHECK_DESTINATION_BEFORE=%s\n' "$destination_check_before"
printf 'NEON_CHECK_DESTINATION_AFTER=%s\n' "$destination_check_after"
printf 'NEON_CHECK_CONSTRAINT_DEF_AFTER=%s\n' "$destination_check_def_after"
printf 'NEON_CHECK_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_CHECK_PROBE_EXIT=%s\n' "$probe_exit"
printf 'NEON_CHECK_PROBE_OUTPUT=%s\n' "$probe_output"

# Fixture preconditions must be exact or this test cannot certify the boundary.
test "$source_check_before" = '1'
test "$destination_check_before" = '0'

# A production rejection is acceptable only when it is actually tied to this CHECK
# incompatibility; unrelated runtime/infrastructure failures must not become a false PASS.
if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'check constraint|products_quantity_nonnegative' <<<"$runtime_output"; then
    echo 'NEON_CHECK_CONSTRAINT_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_CHECK_CONSTRAINT_DRIFT_DETECTED=unverified' >&2
  echo 'Production failed for a reason not demonstrated to be the CHECK-constraint incompatibility.' >&2
  exit 1
fi

# Successful production certification is valid only after the destination carries the
# source CHECK constraint, the missing source row was appended, and a real violating
# destination write is rejected by PostgreSQL.
if [[ "$destination_check_after" == '1' \
      && "$destination_check_def_after" == *'quantity >= 0'* \
      && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' \
      && "$probe_exit" -ne 0 \
      && "$probe_output" == *'products_quantity_nonnegative'* \
      && "$runtime_output" == *'Append sync and verification completed successfully for default.'* \
      && "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_CHECK_CONSTRAINT_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_CHECK_CONSTRAINT_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without proving source CHECK semantics on the writable destination.' >&2
exit 1

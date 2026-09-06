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
create table public.order_lines (
  id bigint primary key,
  quantity integer not null,
  unit_price numeric(12,2) not null,
  line_total numeric(14,2) generated always as ((quantity::numeric * unit_price)) stored
);
insert into public.order_lines (id, quantity, unit_price) values
  (1, 2, 10.00),
  (2, 3, 7.50);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.order_lines (
  id bigint primary key,
  quantity integer not null,
  unit_price numeric(12,2) not null,
  line_total numeric(14,2)
);
insert into public.order_lines (id, quantity, unit_price, line_total) values
  (1, 2, 10.00, 20.00);
SQL

source_generated_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -Atc "select attgenerated from pg_attribute where attrelid='public.order_lines'::regclass and attname='line_total' and not attisdropped;")"
destination_generated_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select attgenerated from pg_attribute where attrelid='public.order_lines'::regclass and attname='line_total' and not attisdropped;")"
source_expression_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -Atc "select pg_get_expr(adbin, adrelid) from pg_attrdef where adrelid='public.order_lines'::regclass and adnum=(select attnum from pg_attribute where attrelid='public.order_lines'::regclass and attname='line_total');")"

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

destination_generated_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select attgenerated from pg_attribute where attrelid='public.order_lines'::regclass and attname='line_total' and not attisdropped;")"
destination_expression_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select coalesce((select pg_get_expr(adbin, adrelid) from pg_attrdef where adrelid='public.order_lines'::regclass and adnum=(select attnum from pg_attribute where attrelid='public.order_lines'::regclass and attname='line_total')), '');")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, quantity, unit_price, line_total from public.order_lines where id=2;")"

# Exercise real writable-destination semantics. A generated source column must not permit
# an arbitrary conflicting value after production has certified schema compatibility.
set +e
probe_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.order_lines (id, quantity, unit_price, line_total) values (900, 2, 10.00, 999.99); select id, quantity, unit_price, line_total from public.order_lines where id=900;" 2>&1)"
probe_exit=$?
set -e

printf 'NEON_GENERATED_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_GENERATED_SOURCE_BEFORE=%s\n' "$source_generated_before"
printf 'NEON_GENERATED_DESTINATION_BEFORE=%s\n' "$destination_generated_before"
printf 'NEON_GENERATED_SOURCE_EXPR=%s\n' "$source_expression_before"
printf 'NEON_GENERATED_DESTINATION_AFTER=%s\n' "$destination_generated_after"
printf 'NEON_GENERATED_DESTINATION_EXPR_AFTER=%s\n' "$destination_expression_after"
printf 'NEON_GENERATED_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_GENERATED_PROBE_EXIT=%s\n' "$probe_exit"
printf 'NEON_GENERATED_PROBE_OUTPUT=%s\n' "$probe_output"

# Exact fixture preconditions.
test "$source_generated_before" = 's'
test -z "$destination_generated_before"
test "$source_expression_before" == *'quantity'*
test "$source_expression_before" == *'unit_price'*

# A non-zero sync is acceptable only when production explicitly detects this generated-column
# incompatibility. Infrastructure or unrelated failures cannot certify the scenario.
if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'generated|line_total' <<<"$runtime_output"; then
    echo 'NEON_GENERATED_COLUMN_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_GENERATED_COLUMN_DRIFT_DETECTED=unverified' >&2
  echo 'Production failed for a reason not demonstrated to be generated-column incompatibility.' >&2
  exit 1
fi

# If sync reports success, the destination must carry source generation semantics, the missing
# source row must be present with its computed value, and an explicit conflicting generated value
# must be rejected by PostgreSQL.
if [[ "$destination_generated_after" == 's' \
      && "$destination_expression_after" == *'quantity'* \
      && "$destination_expression_after" == *'unit_price'* \
      && "$destination_source_row_2" == '2|3|7.50|22.50' \
      && "$probe_exit" -ne 0 \
      && "$probe_output" == *'generated column'* \
      && "$runtime_output" == *'Append sync and verification completed successfully for default.'* \
      && "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_GENERATED_COLUMN_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_GENERATED_COLUMN_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without proving source generated-column semantics on the writable destination.' >&2
exit 1

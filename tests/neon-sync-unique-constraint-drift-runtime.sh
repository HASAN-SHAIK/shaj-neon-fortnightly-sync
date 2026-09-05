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
  sku text not null unique,
  quantity integer not null
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

source_unique_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='u' and pg_get_constraintdef(oid) like 'UNIQUE (sku)%';")"
destination_unique_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='u' and pg_get_constraintdef(oid) like 'UNIQUE (sku)%';")"

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

destination_unique_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='u' and pg_get_constraintdef(oid) like 'UNIQUE (sku)%';")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, sku, quantity from public.products where id=2;")"

# Exercise destination write semantics after sync: if the source UNIQUE invariant was
# preserved, this duplicate SKU insert must fail. A successful insert proves drift.
set +e
probe_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products (id, sku, quantity) values (900, 'SOURCE-SKU-1', 29); select id, sku, quantity from public.products where id=900;" 2>&1)"
probe_exit=$?
set -e

printf 'NEON_UNIQUE_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_UNIQUE_SOURCE_BEFORE=%s\n' "$source_unique_before"
printf 'NEON_UNIQUE_DESTINATION_BEFORE=%s\n' "$destination_unique_before"
printf 'NEON_UNIQUE_DESTINATION_AFTER=%s\n' "$destination_unique_after"
printf 'NEON_UNIQUE_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_UNIQUE_PROBE_EXIT=%s\n' "$probe_exit"
printf 'NEON_UNIQUE_PROBE_OUTPUT=%s\n' "$probe_output"

# Certification passes only if production rejects incompatible schema or converges the
# destination UNIQUE constraint before reporting successful verification.
if [[ "$sync_exit" -ne 0 ]]; then
  echo 'NEON_UNIQUE_CONSTRAINT_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_unique_after" == "$source_unique_before" && "$probe_exit" -ne 0 ]]; then
  echo 'NEON_UNIQUE_CONSTRAINT_DRIFT_DETECTED=true'
  exit 0
fi

if ! grep -Fq 'Append sync and verification completed successfully for default.' <<<"$runtime_output"; then
  echo 'NEON_UNIQUE_CONSTRAINT_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_UNIQUE_CONSTRAINT_DRIFT_DETECTED=false' >&2
echo 'Production reported successful schema/data verification while destination lacked the source UNIQUE constraint and accepted a duplicate source SKU.' >&2
exit 1

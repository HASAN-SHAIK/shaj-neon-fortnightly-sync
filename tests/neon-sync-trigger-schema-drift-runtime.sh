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
  quantity integer not null
);
create function public.reject_negative_quantity() returns trigger
language plpgsql
as $$
begin
  if new.quantity < 0 then
    raise exception 'negative quantity forbidden';
  end if;
  return new;
end;
$$;
create trigger products_quantity_guard
before insert or update of quantity on public.products
for each row execute function public.reject_negative_quantity();
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

read_trigger_count() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "
    select count(*)
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid=t.tgrelid
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where not t.tgisinternal
      and n.nspname='public'
      and c.relname='products'
      and t.tgname='products_quantity_guard';"
}

read_trigger_state() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "
    select t.tgenabled
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid=t.tgrelid
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where not t.tgisinternal
      and n.nspname='public'
      and c.relname='products'
      and t.tgname='products_quantity_guard';"
}

source_trigger_before="$(read_trigger_count "$SOURCE_URL")"
destination_trigger_before="$(read_trigger_count "$DESTINATION_URL")"

set +e
source_probe_output="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -c "insert into public.products (id, sku, quantity) values (900, 'NEGATIVE-SOURCE', -1);" 2>&1)"
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

destination_trigger_after="$(read_trigger_count "$DESTINATION_URL")"
destination_trigger_state="$(read_trigger_state "$DESTINATION_URL")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, sku, quantity from public.products where id=2;")"
destination_trigger_definition="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "
  select pg_get_triggerdef(t.oid)
  from pg_catalog.pg_trigger t
  join pg_catalog.pg_class c on c.oid=t.tgrelid
  join pg_catalog.pg_namespace n on n.oid=c.relnamespace
  where not t.tgisinternal
    and n.nspname='public'
    and c.relname='products'
    and t.tgname='products_quantity_guard';")"

set +e
destination_probe_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -c "insert into public.products (id, sku, quantity) values (900, 'NEGATIVE-DEST', -1);" 2>&1)"
destination_probe_exit=$?
set -e

printf 'NEON_TRIGGER_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_TRIGGER_SOURCE_BEFORE=%s\n' "$source_trigger_before"
printf 'NEON_TRIGGER_DESTINATION_BEFORE=%s\n' "$destination_trigger_before"
printf 'NEON_TRIGGER_SOURCE_PROBE_EXIT=%s\n' "$source_probe_exit"
printf 'NEON_TRIGGER_SOURCE_PROBE_OUTPUT=%s\n' "$source_probe_output"
printf 'NEON_TRIGGER_DESTINATION_AFTER=%s\n' "$destination_trigger_after"
printf 'NEON_TRIGGER_DESTINATION_STATE=%s\n' "$destination_trigger_state"
printf 'NEON_TRIGGER_DESTINATION_DEFINITION=%s\n' "$destination_trigger_definition"
printf 'NEON_TRIGGER_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_TRIGGER_DESTINATION_PROBE_EXIT=%s\n' "$destination_probe_exit"
printf 'NEON_TRIGGER_DESTINATION_PROBE_OUTPUT=%s\n' "$destination_probe_output"

test "$source_trigger_before" = '1'
test "$destination_trigger_before" = '0'
test "$source_probe_exit" -ne 0
grep -Fq 'negative quantity forbidden' <<<"$source_probe_output"

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'trigger|products_quantity_guard|reject_negative_quantity' <<<"$runtime_output"; then
    echo 'NEON_TRIGGER_SCHEMA_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_TRIGGER_SCHEMA_DRIFT_DETECTED=unverified' >&2
  echo 'Production failed for a reason not demonstrated to be trigger-schema incompatibility.' >&2
  exit 1
fi

if [[ "$destination_trigger_after" = '1' \
      && "$destination_trigger_state" = 'O' \
      && "$destination_trigger_definition" == *'products_quantity_guard'* \
      && "$destination_trigger_definition" == *'reject_negative_quantity'* \
      && "$destination_source_row_2" = '2|SOURCE-SKU-2|11' \
      && "$destination_probe_exit" -ne 0 \
      && "$destination_probe_output" == *'negative quantity forbidden'* \
      && "$runtime_output" == *'Append sync and verification completed successfully for default.'* \
      && "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_TRIGGER_SCHEMA_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_TRIGGER_SCHEMA_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without preserving the source user-trigger behavior on the writable destination.' >&2
exit 1

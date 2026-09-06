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
insert into public.products (id, sku, quantity)
values (1, 'SOURCE-SKU-1', 7), (2, 'SOURCE-SKU-2', 11);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
create function public.reject_negative_quantity() returns trigger
language plpgsql
as $$
begin
  return new;
end;
$$;
create trigger products_quantity_guard
before insert or update of quantity on public.products
for each row execute function public.reject_negative_quantity();
insert into public.products (id, sku, quantity)
values (1, 'SOURCE-SKU-1', 7);
SQL

read_function_body() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "
    select pg_get_functiondef(p.oid)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='reject_negative_quantity'
      and pg_get_function_identity_arguments(p.oid)='';"
}

source_body_before="$(read_function_body "$SOURCE_URL")"
destination_body_before="$(read_function_body "$DESTINATION_URL")"

set +e
source_probe_output="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -c "insert into public.products (id, sku, quantity) values (900, 'NEGATIVE-SOURCE', -1);" 2>&1)"
source_probe_exit=$?
set -e

set +e
destination_probe_before_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products (id, sku, quantity) values (901, 'NEGATIVE-DEST-BEFORE', -1) returning id, sku, quantity;" 2>&1)"
destination_probe_before_exit=$?
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

destination_body_after="$(read_function_body "$DESTINATION_URL")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, sku, quantity from public.products where id=2;")"

set +e
destination_probe_after_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products (id, sku, quantity) values (902, 'NEGATIVE-DEST-AFTER', -1) returning id, sku, quantity;" 2>&1)"
destination_probe_after_exit=$?
set -e

printf 'NEON_TRIGGER_FUNCTION_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_TRIGGER_FUNCTION_SOURCE_PROBE_EXIT=%s\n' "$source_probe_exit"
printf 'NEON_TRIGGER_FUNCTION_SOURCE_PROBE_OUTPUT=%s\n' "$source_probe_output"
printf 'NEON_TRIGGER_FUNCTION_DESTINATION_PROBE_BEFORE_EXIT=%s\n' "$destination_probe_before_exit"
printf 'NEON_TRIGGER_FUNCTION_DESTINATION_PROBE_BEFORE_OUTPUT=%s\n' "$destination_probe_before_output"
printf 'NEON_TRIGGER_FUNCTION_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_TRIGGER_FUNCTION_DESTINATION_PROBE_AFTER_EXIT=%s\n' "$destination_probe_after_exit"
printf 'NEON_TRIGGER_FUNCTION_DESTINATION_PROBE_AFTER_OUTPUT=%s\n' "$destination_probe_after_output"
printf 'NEON_TRIGGER_FUNCTION_SOURCE_BODY_HAS_GUARD=%s\n' "$(grep -Fq 'negative quantity forbidden' <<<"$source_body_before" && echo true || echo false)"
printf 'NEON_TRIGGER_FUNCTION_DESTINATION_BODY_BEFORE_HAS_GUARD=%s\n' "$(grep -Fq 'negative quantity forbidden' <<<"$destination_body_before" && echo true || echo false)"
printf 'NEON_TRIGGER_FUNCTION_DESTINATION_BODY_AFTER_HAS_GUARD=%s\n' "$(grep -Fq 'negative quantity forbidden' <<<"$destination_body_after" && echo true || echo false)"

test "$source_probe_exit" -ne 0
grep -Fq 'negative quantity forbidden' <<<"$source_probe_output"
test "$destination_probe_before_exit" -eq 0
grep -Fq '901|NEGATIVE-DEST-BEFORE|-1' <<<"$destination_probe_before_output"
grep -Fq 'negative quantity forbidden' <<<"$source_body_before"
! grep -Fq 'negative quantity forbidden' <<<"$destination_body_before"

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'function|trigger|reject_negative_quantity|products_quantity_guard' <<<"$runtime_output"; then
    echo 'NEON_TRIGGER_FUNCTION_BODY_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_TRIGGER_FUNCTION_BODY_DRIFT_DETECTED=unverified' >&2
  echo 'Production failed for a reason not demonstrated to be trigger-function incompatibility.' >&2
  exit 1
fi

if grep -Fq 'negative quantity forbidden' <<<"$destination_body_after" \
   && [[ "$destination_source_row_2" = '2|SOURCE-SKU-2|11' ]] \
   && [[ "$destination_probe_after_exit" -ne 0 ]] \
   && [[ "$destination_probe_after_output" == *'negative quantity forbidden'* ]] \
   && [[ "$runtime_output" == *'Append sync and verification completed successfully for default.'* ]] \
   && [[ "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_TRIGGER_FUNCTION_BODY_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_TRIGGER_FUNCTION_BODY_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without converging the source trigger function body on the writable destination.' >&2
exit 1

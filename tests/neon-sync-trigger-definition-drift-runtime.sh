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
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create function public.reject_negative_quantity() returns trigger language plpgsql as $$
begin
  if new.quantity < 0 then raise exception 'negative quantity forbidden'; end if;
  return new;
end;
$$;
create trigger products_quantity_guard
before insert or update of quantity on public.products
for each row execute function public.reject_negative_quantity();
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create function public.reject_negative_quantity() returns trigger language plpgsql as $$
begin
  if new.quantity < 0 then raise exception 'negative quantity forbidden'; end if;
  return new;
end;
$$;
create trigger products_quantity_guard
before insert on public.products
for each row execute function public.reject_negative_quantity();
insert into public.products values (1,'SOURCE-SKU-1',7);
SQL

read_trigger_def() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select pg_get_triggerdef(t.oid,true) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='products' and t.tgname='products_quantity_guard' and not t.tgisinternal;"
}
source_def_before="$(read_trigger_def "$SOURCE_URL")"
destination_def_before="$(read_trigger_def "$DESTINATION_URL")"

set +e
source_update_output="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -c "update public.products set quantity=-1 where id=1;" 2>&1)"
source_update_exit=$?
set -e
set +e
destination_update_before_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "update public.products set quantity=-1 where id=1 returning id,sku,quantity;" 2>&1)"
destination_update_before_exit=$?
set -e
psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -c "update public.products set quantity=7 where id=1;" >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_URL" DESTINATION_DATABASE_URL="$DESTINATION_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_def_after="$(read_trigger_def "$DESTINATION_URL")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_update_after_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "update public.products set quantity=-1 where id=1 returning id,sku,quantity;" 2>&1)"
destination_update_after_exit=$?
set -e

printf 'NEON_TRIGGER_DEFINITION_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_TRIGGER_DEFINITION_SOURCE_BEFORE=%s\n' "$source_def_before"
printf 'NEON_TRIGGER_DEFINITION_DESTINATION_BEFORE=%s\n' "$destination_def_before"
printf 'NEON_TRIGGER_DEFINITION_DESTINATION_AFTER=%s\n' "$destination_def_after"
printf 'NEON_TRIGGER_DEFINITION_SOURCE_UPDATE_EXIT=%s\n' "$source_update_exit"
printf 'NEON_TRIGGER_DEFINITION_SOURCE_UPDATE_OUTPUT=%s\n' "$source_update_output"
printf 'NEON_TRIGGER_DEFINITION_DESTINATION_UPDATE_BEFORE_EXIT=%s\n' "$destination_update_before_exit"
printf 'NEON_TRIGGER_DEFINITION_DESTINATION_UPDATE_BEFORE_OUTPUT=%s\n' "$destination_update_before_output"
printf 'NEON_TRIGGER_DEFINITION_DESTINATION_UPDATE_AFTER_EXIT=%s\n' "$destination_update_after_exit"
printf 'NEON_TRIGGER_DEFINITION_DESTINATION_UPDATE_AFTER_OUTPUT=%s\n' "$destination_update_after_output"
printf 'NEON_TRIGGER_DEFINITION_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_update_exit" -ne 0
grep -Fq 'negative quantity forbidden' <<<"$source_update_output"
test "$destination_update_before_exit" -eq 0
grep -Fq '1|SOURCE-SKU-1|-1' <<<"$destination_update_before_output"
[[ "$source_def_before" == *'UPDATE OF quantity'* ]]
[[ "$destination_def_before" != *'UPDATE OF quantity'* ]]

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'trigger|products_quantity_guard' <<<"$runtime_output"; then
    echo 'NEON_TRIGGER_DEFINITION_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_TRIGGER_DEFINITION_DRIFT_DETECTED=unverified' >&2
  exit 1
fi

if [[ "$destination_def_after" == *'UPDATE OF quantity'* ]] \
  && [[ "$destination_source_row_2" = '2|SOURCE-SKU-2|11' ]] \
  && [[ "$destination_update_after_exit" -ne 0 ]] \
  && [[ "$destination_update_after_output" == *'negative quantity forbidden'* ]] \
  && [[ "$runtime_output" == *'Append sync and verification completed successfully for default.'* ]] \
  && [[ "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_TRIGGER_DEFINITION_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_TRIGGER_DEFINITION_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without converging source trigger event semantics.' >&2
exit 1

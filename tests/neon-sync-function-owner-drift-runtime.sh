#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_POSTGRES_URL="$SOURCE_ADMIN_URL"
DESTINATION_POSTGRES_URL="$DESTINATION_ADMIN_URL"
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
create function public.pricing_guard() returns text language sql as $$select 'safe'::text$$;
alter function public.pricing_guard() owner to cycle_owner;
revoke all on function public.pricing_guard() from public;
grant execute on function public.pricing_guard() to cycle_app;
grant usage on schema public to cycle_other, cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
create function public.pricing_guard() returns text language sql as $$select 'safe'::text$$;
alter function public.pricing_guard() owner to cycle_other;
revoke all on function public.pricing_guard() from public;
grant execute on function public.pricing_guard() to cycle_app;
grant usage on schema public to cycle_other, cycle_app;
SQL

owner_of_function() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(p.proowner) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='pricing_guard' and pg_get_function_identity_arguments(p.oid)='';"
}
function_value() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc 'select public.pricing_guard();'
}
replace_as_other() {
  local url="$1"
  local value="$2"
  psql "$url" -v ON_ERROR_STOP=1 -c "create or replace function public.pricing_guard() returns text language sql as 'select ''${value}''::text';"
}

source_owner_before="$(owner_of_function "$SOURCE_POSTGRES_URL")"
destination_owner_before="$(owner_of_function "$DESTINATION_POSTGRES_URL")"
source_app_execute_before="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_function_privilege('cycle_app','public.pricing_guard()','EXECUTE');")"
destination_app_execute_before="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_function_privilege('cycle_app','public.pricing_guard()','EXECUTE');")"
source_app_value_before="$(function_value "$SOURCE_APP_URL")"
destination_app_value_before="$(function_value "$DESTINATION_APP_URL")"

set +e
source_replace_output="$(replace_as_other "$SOURCE_OTHER_URL" 'tampered' 2>&1)"
source_replace_exit=$?
set -e
set +e
destination_replace_output="$(replace_as_other "$DESTINATION_OTHER_URL" 'tampered' 2>&1)"
destination_replace_exit=$?
set -e
destination_app_value_after_probe="$(function_value "$DESTINATION_APP_URL")"

printf 'BEFORE\n'
printf 'source function owner=%s\n' "$source_owner_before"
printf 'destination function owner=%s\n' "$destination_owner_before"
printf 'source cycle_app EXECUTE privilege=%s\n' "$source_app_execute_before"
printf 'destination cycle_app EXECUTE privilege=%s\n' "$destination_app_execute_before"
printf 'source cycle_app value=%s\n' "$source_app_value_before"
printf 'destination cycle_app value=%s\n' "$destination_app_value_before"
printf 'source cycle_other replace exit=%s\n' "$source_replace_exit"
printf 'source cycle_other replace output=%s\n' "$source_replace_output"
printf 'destination cycle_other replace exit=%s\n' "$destination_replace_exit"
printf 'destination cycle_other replace output=%s\n' "$destination_replace_output"
printf 'destination cycle_app value after owner probe=%s\n' "$destination_app_value_after_probe"

if [[ "$source_owner_before" != 'cycle_owner' || "$destination_owner_before" != 'cycle_other' || "$source_app_execute_before" != 't' || "$destination_app_execute_before" != 't' || "$source_app_value_before" != 'safe' || "$destination_app_value_before" != 'safe' || "$source_replace_exit" -eq 0 || "$destination_replace_exit" -ne 0 || "$destination_app_value_after_probe" != 'tampered' ]]; then
  echo 'Fixture did not establish isolated function ownership drift.' >&2
  exit 2
fi

# Restore destination routine semantics before production sync while preserving ownership drift.
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
create or replace function public.pricing_guard() returns text language sql as $$select 'safe'::text$$;
alter function public.pricing_guard() owner to cycle_other;
revoke all on function public.pricing_guard() from public;
grant execute on function public.pricing_guard() to cycle_app;
SQL
[[ "$(function_value "$DESTINATION_APP_URL")" == 'safe' ]]

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FUNCTION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi '(function|routine).*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*(function|routine).*(incompatib|drift|mismatch)|(incompatib|drift|mismatch).*(function|routine).*(owner|ownership)' <<<"$runtime_output"; then
    echo 'NEON_FUNCTION_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FUNCTION_OWNER_DRIFT_FAIL_CLOSED=false'
  echo 'Production sync failed for a reason not identified as function ownership incompatibility.' >&2
  exit 1
fi

destination_owner_after="$(owner_of_function "$DESTINATION_POSTGRES_URL")"
destination_app_execute_after="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_function_privilege('cycle_app','public.pricing_guard()','EXECUTE');")"
destination_app_value_before_final_probe="$(function_value "$DESTINATION_APP_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_replace_output="$(replace_as_other "$DESTINATION_OTHER_URL" 'tampered-after-sync' 2>&1)"
destination_after_replace_exit=$?
set -e
destination_app_value_after_final_probe="$(function_value "$DESTINATION_APP_URL")"

printf 'AFTER\n'
printf 'destination function owner=%s\n' "$destination_owner_after"
printf 'destination cycle_app EXECUTE privilege=%s\n' "$destination_app_execute_after"
printf 'destination cycle_app value before final owner probe=%s\n' "$destination_app_value_before_final_probe"
printf 'appended source row=%s\n' "$destination_source_row_2"
printf 'destination cycle_other replace exit=%s\n' "$destination_after_replace_exit"
printf 'destination cycle_other replace output=%s\n' "$destination_after_replace_output"
printf 'destination cycle_app value after final owner probe=%s\n' "$destination_app_value_after_final_probe"
printf 'NEON_FUNCTION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_owner_after" == 'cycle_owner' && "$destination_app_execute_after" == 't' && "$destination_app_value_before_final_probe" == 'safe' && "$destination_after_replace_exit" -ne 0 && "$destination_app_value_after_final_probe" == 'safe' && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_FUNCTION_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_FUNCTION_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained routine ownership authority that source assigns to a different role.' >&2
exit 1

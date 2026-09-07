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
create view public.stock_snapshot as select id, sku, quantity from public.products;
alter view public.stock_snapshot owner to cycle_owner;
grant usage, create on schema public to cycle_other;
grant usage on schema public to cycle_app;
grant select on public.stock_snapshot to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
create view public.stock_snapshot as select id, sku, quantity from public.products;
alter view public.stock_snapshot owner to cycle_other;
grant usage, create on schema public to cycle_other;
grant usage on schema public to cycle_app;
grant select on public.stock_snapshot to cycle_app;
SQL

owner_of_view() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.relowner) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='stock_snapshot' and c.relkind='v';"
}
replace_view_as_other() {
  local url="$1"
  local expression="$2"
  psql "$url" -v ON_ERROR_STOP=1 -c "create or replace view public.stock_snapshot as select id, sku, ${expression} as quantity from public.products;"
}
view_value_as_app() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.stock_snapshot where id=1;"
}

source_owner_before="$(owner_of_view "$SOURCE_POSTGRES_URL")"
destination_owner_before="$(owner_of_view "$DESTINATION_POSTGRES_URL")"
source_app_select_before="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_app','public.stock_snapshot','SELECT');")"
destination_app_select_before="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_app','public.stock_snapshot','SELECT');")"
source_app_value_before="$(view_value_as_app "$SOURCE_APP_URL")"
destination_app_value_before="$(view_value_as_app "$DESTINATION_APP_URL")"

set +e
source_replace_output="$(replace_view_as_other "$SOURCE_OTHER_URL" 'quantity + 100' 2>&1)"
source_replace_exit=$?
set -e
set +e
destination_replace_output="$(replace_view_as_other "$DESTINATION_OTHER_URL" 'quantity + 100' 2>&1)"
destination_replace_exit=$?
set -e
destination_app_value_after_probe="$(view_value_as_app "$DESTINATION_APP_URL")"

printf 'BEFORE\n'
printf 'source view owner=%s\n' "$source_owner_before"
printf 'destination view owner=%s\n' "$destination_owner_before"
printf 'source cycle_app SELECT=%s\n' "$source_app_select_before"
printf 'destination cycle_app SELECT=%s\n' "$destination_app_select_before"
printf 'source cycle_app value=%s\n' "$source_app_value_before"
printf 'destination cycle_app value=%s\n' "$destination_app_value_before"
printf 'source cycle_other replace exit=%s\n' "$source_replace_exit"
printf 'source cycle_other replace output=%s\n' "$source_replace_output"
printf 'destination cycle_other replace exit=%s\n' "$destination_replace_exit"
printf 'destination cycle_other replace output=%s\n' "$destination_replace_output"
printf 'destination cycle_app value after owner probe=%s\n' "$destination_app_value_after_probe"

if [[ "$source_owner_before" != 'cycle_owner' || "$destination_owner_before" != 'cycle_other' || "$source_app_select_before" != 't' || "$destination_app_select_before" != 't' || "$source_app_value_before" != '1|SOURCE-SKU-1|7' || "$destination_app_value_before" != '1|SOURCE-SKU-1|7' || "$source_replace_exit" -eq 0 || "$destination_replace_exit" -ne 0 || "$destination_app_value_after_probe" != '1|SOURCE-SKU-1|107' ]]; then
  echo 'Fixture did not establish isolated view ownership drift.' >&2
  exit 2
fi

# Restore destination view semantics before production synchronization while preserving ownership drift.
replace_view_as_other "$DESTINATION_OTHER_URL" 'quantity' >/dev/null
[[ "$(owner_of_view "$DESTINATION_POSTGRES_URL")" == 'cycle_other' ]]
[[ "$(view_value_as_app "$DESTINATION_APP_URL")" == '1|SOURCE-SKU-1|7' ]]

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_VIEW_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'view.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*view.*(incompatib|drift|mismatch)|(incompatib|drift|mismatch).*view.*(owner|ownership)' <<<"$runtime_output"; then
    echo 'NEON_VIEW_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_VIEW_OWNER_DRIFT_FAIL_CLOSED=false'
  echo 'Production sync failed for a reason not identified as view ownership incompatibility.' >&2
  exit 1
fi

destination_owner_after="$(owner_of_view "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_app_value_before_final_probe="$(view_value_as_app "$DESTINATION_APP_URL")"

set +e
destination_after_replace_output="$(replace_view_as_other "$DESTINATION_OTHER_URL" 'quantity + 200' 2>&1)"
destination_after_replace_exit=$?
set -e
destination_app_value_after_final_probe="$(view_value_as_app "$DESTINATION_APP_URL")"

printf 'AFTER\n'
printf 'destination view owner=%s\n' "$destination_owner_after"
printf 'destination cycle_app SELECT=%s\n' "$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_app','public.stock_snapshot','SELECT');")"
printf 'destination cycle_app value before final owner probe=%s\n' "$destination_app_value_before_final_probe"
printf 'appended source row=%s\n' "$destination_source_row_2"
printf 'destination cycle_other replace exit=%s\n' "$destination_after_replace_exit"
printf 'destination cycle_other replace output=%s\n' "$destination_after_replace_output"
printf 'destination cycle_app value after final owner probe=%s\n' "$destination_app_value_after_final_probe"
printf 'NEON_VIEW_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_owner_after" == 'cycle_owner' && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' && "$destination_app_value_before_final_probe" == '1|SOURCE-SKU-1|7' && "$destination_after_replace_exit" -ne 0 ]]; then
  echo 'NEON_VIEW_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_VIEW_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained view ownership authority that source assigns to a different role.' >&2
exit 1

#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set check_function_bodies = on;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set check_function_bodies = off;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
grant usage, create on schema public to cycle_app;
grant select on public.products to cycle_app;
insert into public.products values (1,'SOURCE-SKU-1',7);
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'check_function_bodies=%';"
}

probe_function_creation() {
  local url="$1" fn="$2" output code
  set +e
  output="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "create function public.${fn}() returns integer language sql as \$body\$ select quantity from public.never_created_relation limit 1 \$body\$;" 2>&1)"
  code=$?
  set -e
  if [[ "$code" -eq 0 ]]; then
    psql "$url" -X -v ON_ERROR_STOP=1 -At -c "drop function public.${fn}();" >/dev/null
  fi
  printf '%s|%s' "$code" "$(printf '%s' "$output" | tr '\n' '\036')"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_function_creation "$SOURCE_APP_URL" cycle_probe_before)"
destination_probe="$(probe_function_creation "$DESTINATION_APP_URL" cycle_probe_before)"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app function probe=%s\ndestination app function probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"

if [[ "${source_setting,,}" != 'check_function_bodies=on' || "${destination_setting,,}" != 'check_function_bodies=off' ]]; then
  echo 'Fixture did not establish check_function_bodies drift.' >&2; exit 2
fi
if [[ "$source_probe" != 1\|* || "$source_probe" != *'relation "public.never_created_relation" does not exist'* ]]; then
  echo "Source validation probe did not reject invalid function body as expected: $source_probe" >&2; exit 2
fi
if [[ "$destination_probe" != 0\|* || "$destination_probe" != *'CREATE FUNCTION'* ]]; then
  echo "Destination validation-disabled probe did not accept invalid function body as expected: $destination_probe" >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_CHECK_FUNCTION_BODIES_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'check_function_bodies|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_CHECK_FUNCTION_BODIES_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_CHECK_FUNCTION_BODIES_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(probe_function_creation "$SOURCE_APP_URL" cycle_probe_after)"
destination_probe_after="$(probe_function_creation "$DESTINATION_APP_URL" cycle_probe_after)"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app function probe=%s\ndestination app function probe=%s\nNEON_ROLE_CHECK_FUNCTION_BODIES_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$source_probe_after" "$destination_probe_after" "$sync_exit"

if [[ "${destination_setting_after,,}" == 'check_function_bodies=on' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == 1\|* && "$destination_probe_after" == *'relation "public.never_created_relation" does not exist'* ]]; then
  echo 'NEON_ROLE_CHECK_FUNCTION_BODIES_DRIFT_DETECTED=true'; exit 0
fi
echo 'NEON_ROLE_CHECK_FUNCTION_BODIES_DRIFT_DETECTED=false'
exit 1

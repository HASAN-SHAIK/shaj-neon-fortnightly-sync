#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' valid until '2000-01-01 00:00:00+00';"
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

valid_until() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select coalesce(rolvaliduntil::text,'infinity') from pg_authid where rolname='cycle_app';"
}
app_select() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products order by id;"
}

source_valid_before="$(valid_until "$SOURCE_ADMIN_URL")"
destination_valid_before="$(valid_until "$DESTINATION_ADMIN_URL")"
set +e
source_select_output="$(app_select "$SOURCE_APP_URL" 2>&1)"; source_select_exit=$?
destination_select_output="$(app_select "$DESTINATION_APP_URL" 2>&1)"; destination_select_exit=$?
set -e
printf 'BEFORE\nsource cycle_app valid until=%s\ndestination cycle_app valid until=%s\n' "$source_valid_before" "$destination_valid_before"
printf 'source cycle_app connection/select exit=%s\nsource output=%s\n' "$source_select_exit" "$source_select_output"
printf 'destination cycle_app connection/select exit=%s\ndestination output=%s\n' "$destination_select_exit" "$destination_select_output"

if [[ "$source_valid_before" != 2000-* || "$destination_valid_before" != infinity || "$source_select_exit" -eq 0 || "$destination_select_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated role VALID UNTIL drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_VALID_UNTIL_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'valid until|password.*expir|credential.*expir|role.*expir' <<<"$runtime_output"; then
    echo 'NEON_ROLE_VALID_UNTIL_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_VALID_UNTIL_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_valid_after="$(valid_until "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_select_after_output="$(app_select "$DESTINATION_APP_URL" 2>&1)"; destination_select_after_exit=$?
set -e
printf 'AFTER\ndestination cycle_app valid until=%s\nappended source row=%s\n' "$destination_valid_after" "$destination_row_2"
printf 'destination cycle_app connection/select exit=%s\ndestination output=%s\nNEON_ROLE_VALID_UNTIL_DRIFT_SYNC_EXIT=%s\n' "$destination_select_after_exit" "$destination_select_after_output" "$sync_exit"

if [[ "$destination_valid_after" == 2000-* && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_select_after_exit" -ne 0 ]]; then
  echo 'NEON_ROLE_VALID_UNTIL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_VALID_UNTIL_DRIFT_DETECTED=false'
echo 'Destination retained a non-expiring application credential while source credential is expired.' >&2
exit 1

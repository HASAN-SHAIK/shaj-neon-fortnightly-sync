#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' connection limit 1;"
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' connection limit -1;"
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

connection_limit() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolconnlimit from pg_roles where rolname='cycle_app';"
}
wait_for_app_session() {
  local admin_url="$1"
  for _ in $(seq 1 30); do
    if [[ "$(psql "$admin_url" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_stat_activity where usename='cycle_app' and application_name='cycle_d_hold';")" -ge 1 ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}
start_hold() {
  local url="$1"
  PGAPPNAME=cycle_d_hold psql "$url" -v ON_ERROR_STOP=1 -Atc 'select pg_sleep(12);' >/tmp/cycle-d-hold.out 2>/tmp/cycle-d-hold.err &
  echo $!
}
second_connection() {
  PGAPPNAME=cycle_d_probe psql "$1" -v ON_ERROR_STOP=1 -Atc 'select 1;'
}

source_limit_before="$(connection_limit "$SOURCE_ADMIN_URL")"
destination_limit_before="$(connection_limit "$DESTINATION_ADMIN_URL")"
source_hold_pid="$(start_hold "$SOURCE_APP_URL")"
wait_for_app_session "$SOURCE_ADMIN_URL" || { echo 'Source hold connection did not become active.' >&2; kill "$source_hold_pid" 2>/dev/null || true; exit 2; }
set +e
source_second_output="$(second_connection "$SOURCE_APP_URL" 2>&1)"; source_second_exit=$?
set -e
kill "$source_hold_pid" 2>/dev/null || true
wait "$source_hold_pid" 2>/dev/null || true

destination_hold_pid="$(start_hold "$DESTINATION_APP_URL")"
wait_for_app_session "$DESTINATION_ADMIN_URL" || { echo 'Destination hold connection did not become active.' >&2; kill "$destination_hold_pid" 2>/dev/null || true; exit 2; }
set +e
destination_second_output="$(second_connection "$DESTINATION_APP_URL" 2>&1)"; destination_second_exit=$?
set -e
kill "$destination_hold_pid" 2>/dev/null || true
wait "$destination_hold_pid" 2>/dev/null || true

printf 'BEFORE\nsource cycle_app rolconnlimit=%s\ndestination cycle_app rolconnlimit=%s\n' "$source_limit_before" "$destination_limit_before"
printf 'source second concurrent connection exit=%s\nsource output=%s\n' "$source_second_exit" "$source_second_output"
printf 'destination second concurrent connection exit=%s\ndestination output=%s\n' "$destination_second_exit" "$destination_second_output"

if [[ "$source_limit_before" != 1 || "$destination_limit_before" != -1 || "$source_second_exit" -eq 0 || "$destination_second_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated role CONNECTION LIMIT drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_CONNECTION_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'rolconnlimit|connection[ _-]*limit|role.*limit' <<<"$runtime_output"; then
    echo 'NEON_ROLE_CONNECTION_LIMIT_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_CONNECTION_LIMIT_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_limit_after="$(connection_limit "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_hold_after_pid="$(start_hold "$DESTINATION_APP_URL")"
wait_for_app_session "$DESTINATION_ADMIN_URL" || { echo 'Destination post-sync hold connection did not become active.' >&2; kill "$destination_hold_after_pid" 2>/dev/null || true; exit 2; }
set +e
destination_second_after_output="$(second_connection "$DESTINATION_APP_URL" 2>&1)"; destination_second_after_exit=$?
set -e
kill "$destination_hold_after_pid" 2>/dev/null || true
wait "$destination_hold_after_pid" 2>/dev/null || true

printf 'AFTER\ndestination cycle_app rolconnlimit=%s\nappended source row=%s\n' "$destination_limit_after" "$destination_row_2"
printf 'destination second concurrent connection exit=%s\ndestination output=%s\nNEON_ROLE_CONNECTION_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$destination_second_after_exit" "$destination_second_after_output" "$sync_exit"

if [[ "$destination_limit_after" == 1 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_second_after_exit" -ne 0 ]]; then
  echo 'NEON_ROLE_CONNECTION_LIMIT_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_CONNECTION_LIMIT_DRIFT_DETECTED=false'
echo 'Destination retained an unlimited application-role connection budget while source restricts the role to one concurrent connection.' >&2
exit 1

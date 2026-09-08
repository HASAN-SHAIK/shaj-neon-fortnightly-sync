#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:cycle-app-password@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:cycle-app-password@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-app-password';
alter role cycle_app set lock_timeout = '100ms';
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-app-password';
alter role cycle_app set lock_timeout = '0';
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
grant usage on schema public to cycle_app;
grant select, update on public.products to cycle_app;
SQL
done

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select coalesce(array_to_string(setconfig,','),'') from pg_db_role_setting s join pg_roles r on r.oid=s.setrole where r.rolname='cycle_app' and s.setdatabase=0;"
}

start_locker() {
  local admin_url="$1"
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "begin; update public.products set quantity=quantity where id=1; select pg_sleep(5); rollback;" >/tmp/cycle-d-locker-$RANDOM.log 2>&1 &
  echo $!
}

probe_update() {
  local url="$1"
  set +e
  local output
  output="$(timeout 1.5s psql "$url" -v ON_ERROR_STOP=1 -At -c "update public.products set quantity=quantity+1 where id=1 returning id,sku,quantity;" 2>&1)"
  local code=$?
  set -e
  output="${output//$'\n'/\\n}"
  printf '%s|%s\n' "$code" "$output"
}

run_lock_boundary() {
  local source_locker destination_locker source_probe destination_probe
  source_locker="$(start_locker "$SOURCE_ADMIN_URL")"
  destination_locker="$(start_locker "$DESTINATION_ADMIN_URL")"
  sleep 0.5
  source_probe="$(probe_update "$SOURCE_APP_URL")"
  destination_probe="$(probe_update "$DESTINATION_APP_URL")"
  kill "$source_locker" "$destination_locker" 2>/dev/null || true
  wait "$source_locker" 2>/dev/null || true
  wait "$destination_locker" 2>/dev/null || true
  printf '%s\n%s\n' "$source_probe" "$destination_probe"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
mapfile -t before_probes < <(run_lock_boundary)
source_probe="${before_probes[0]}"
destination_probe="${before_probes[1]}"

printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\n' "$source_setting" "$destination_setting"
printf 'source blocked update=%s\ndestination blocked update=%s\n' "$source_probe" "$destination_probe"

if [[ "$source_setting" != 'lock_timeout=100ms' || "$destination_setting" != 'lock_timeout=0' ]]; then
  echo 'Fixture did not establish role lock_timeout drift.' >&2
  exit 2
fi
if [[ "$source_probe" != 1\|* || "$source_probe" != *'canceling statement due to lock timeout'* ]]; then
  echo 'Source blocked application update did not fail on lock_timeout as expected.' >&2
  exit 2
fi
if [[ "$destination_probe" != 124\|* ]]; then
  echo 'Destination blocked application update did not remain blocked past the external probe bound.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_LOCK_TIMEOUT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'lock_timeout|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_LOCK_TIMEOUT_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_LOCK_TIMEOUT_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
mapfile -t after_probes < <(run_lock_boundary)
source_probe_after="${after_probes[0]}"
destination_probe_after="${after_probes[1]}"

printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource blocked update=%s\ndestination blocked update=%s\nNEON_ROLE_LOCK_TIMEOUT_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$source_probe_after" "$destination_probe_after" "$sync_exit"

if [[ "$destination_setting_after" == 'lock_timeout=100ms' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == 1\|* && "$destination_probe_after" == *'canceling statement due to lock timeout'* ]]; then
  echo 'NEON_ROLE_LOCK_TIMEOUT_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_LOCK_TIMEOUT_DRIFT_DETECTED=false'
exit 1

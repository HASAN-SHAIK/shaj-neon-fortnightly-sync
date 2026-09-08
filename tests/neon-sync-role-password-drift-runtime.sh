#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_NEW_URL='postgresql://cycle_app:cycle-new-password@127.0.0.1:55432/cycle_d_source'
SOURCE_APP_OLD_URL='postgresql://cycle_app:cycle-old-password@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_NEW_URL='postgresql://cycle_app:cycle-new-password@127.0.0.1:55433/cycle_d_destination'
DESTINATION_APP_OLD_URL='postgresql://cycle_app:cycle-old-password@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-new-password';
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-old-password';
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
grant select on public.products to cycle_app;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

probe_select() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;"
}

set +e
source_new_output="$(probe_select "$SOURCE_APP_NEW_URL" 2>&1)"; source_new_exit=$?
source_old_output="$(probe_select "$SOURCE_APP_OLD_URL" 2>&1)"; source_old_exit=$?
destination_new_output="$(probe_select "$DESTINATION_APP_NEW_URL" 2>&1)"; destination_new_exit=$?
destination_old_output="$(probe_select "$DESTINATION_APP_OLD_URL" 2>&1)"; destination_old_exit=$?
set -e

printf 'BEFORE\nsource rotated credential exit=%s\nsource rotated output=%s\n' "$source_new_exit" "$source_new_output"
printf 'source stale credential exit=%s\nsource stale output=%s\n' "$source_old_exit" "$source_old_output"
printf 'destination rotated credential exit=%s\ndestination rotated output=%s\n' "$destination_new_exit" "$destination_new_output"
printf 'destination stale credential exit=%s\ndestination stale output=%s\n' "$destination_old_exit" "$destination_old_output"

if [[ "$source_new_exit" -ne 0 || "$source_new_output" != '1|SOURCE-SKU-1|7' || "$source_old_exit" -eq 0 || "$destination_new_exit" -eq 0 || "$destination_old_exit" -ne 0 || "$destination_old_output" != '1|SOURCE-SKU-1|7' ]]; then
  echo 'Fixture did not establish isolated password-rotation credential drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_PASSWORD_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'password|credential|pg_authid|rolpassword' <<<"$runtime_output"; then
    echo 'NEON_ROLE_PASSWORD_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_PASSWORD_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_new_after_output="$(probe_select "$DESTINATION_APP_NEW_URL" 2>&1)"; destination_new_after_exit=$?
destination_old_after_output="$(probe_select "$DESTINATION_APP_OLD_URL" 2>&1)"; destination_old_after_exit=$?
set -e

printf 'AFTER\nappended source row=%s\n' "$destination_row_2"
printf 'destination rotated credential exit=%s\ndestination rotated output=%s\n' "$destination_new_after_exit" "$destination_new_after_output"
printf 'destination stale credential exit=%s\ndestination stale output=%s\nNEON_ROLE_PASSWORD_DRIFT_SYNC_EXIT=%s\n' "$destination_old_after_exit" "$destination_old_after_output" "$sync_exit"

if [[ "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_new_after_exit" -eq 0 && "$destination_new_after_output" == '1|SOURCE-SKU-1|7' && "$destination_old_after_exit" -ne 0 ]]; then
  echo 'NEON_ROLE_PASSWORD_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_PASSWORD_DRIFT_DETECTED=false'
exit 1

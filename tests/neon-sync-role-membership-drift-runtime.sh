#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role privileged_writer nologin;"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app;'

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
grant usage on schema public to cycle_app, privileged_writer;
grant select on public.products to cycle_app;
grant insert on public.products to privileged_writer;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

membership() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_has_role('cycle_app','privileged_writer','member');"
}
app_insert() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "insert into public.products values (900,'MEMBERSHIP-PROBE',1) returning id;"
}

source_member_before="$(membership "$SOURCE_ADMIN_URL")"
destination_member_before="$(membership "$DESTINATION_ADMIN_URL")"
set +e
source_insert_output="$(app_insert "$SOURCE_APP_URL" 2>&1)"; source_insert_exit=$?
destination_insert_output="$(app_insert "$DESTINATION_APP_URL" 2>&1)"; destination_insert_exit=$?
set -e
printf 'BEFORE\nsource cycle_app member of privileged_writer=%s\ndestination cycle_app member of privileged_writer=%s\n' "$source_member_before" "$destination_member_before"
printf 'source cycle_app inherited insert exit=%s\nsource output=%s\n' "$source_insert_exit" "$source_insert_output"
printf 'destination cycle_app inherited insert exit=%s\ndestination output=%s\n' "$destination_insert_exit" "$destination_insert_output"

if [[ "$source_member_before" != f || "$destination_member_before" != t || "$source_insert_exit" -eq 0 || "$destination_insert_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated role-membership drift.' >&2
  exit 2
fi
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "delete from public.products where id=900;"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_MEMBERSHIP_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'role.*membership|membership.*role|inherited.*privilege' <<<"$runtime_output"; then
    echo 'NEON_ROLE_MEMBERSHIP_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_MEMBERSHIP_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_member_after="$(membership "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_insert_after_output="$(app_insert "$DESTINATION_APP_URL" 2>&1)"; destination_insert_after_exit=$?
set -e
printf 'AFTER\ndestination cycle_app member of privileged_writer=%s\nappended source row=%s\n' "$destination_member_after" "$destination_row_2"
printf 'destination cycle_app inherited insert exit=%s\ndestination output=%s\nNEON_ROLE_MEMBERSHIP_DRIFT_SYNC_EXIT=%s\n' "$destination_insert_after_exit" "$destination_insert_after_output" "$sync_exit"

if [[ "$destination_member_after" == f && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_insert_after_exit" -ne 0 ]]; then
  echo 'NEON_ROLE_MEMBERSHIP_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_MEMBERSHIP_DRIFT_DETECTED=false'
echo 'Destination retained role membership and inherited write authority absent on source.' >&2
exit 1

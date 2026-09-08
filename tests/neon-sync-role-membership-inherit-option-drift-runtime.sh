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
  psql "$root_url" -v ON_ERROR_STOP=1 <<'SQL'
create role privileged_writer nologin;
create role cycle_app login password 'app';
SQL
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app with inherit false;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app with inherit true;'
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

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

inherit_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select m.inherit_option from pg_auth_members m join pg_roles r on r.oid=m.roleid join pg_roles u on u.oid=m.member where r.rolname='privileged_writer' and u.rolname='cycle_app';"
}
probe_insert() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "insert into public.products(id,sku,quantity) values ($2,'MEMBERSHIP-INHERIT-PROBE',1);"
}

source_inherit_before="$(inherit_option "$SOURCE_ADMIN_URL")"
destination_inherit_before="$(inherit_option "$DESTINATION_ADMIN_URL")"
set +e
source_insert_output="$(probe_insert "$SOURCE_APP_URL" 900 2>&1)"; source_insert_exit=$?
destination_insert_output="$(probe_insert "$DESTINATION_APP_URL" 900 2>&1)"; destination_insert_exit=$?
set -e

printf 'BEFORE\nsource membership inherit_option=%s\ndestination membership inherit_option=%s\n' "$source_inherit_before" "$destination_inherit_before"
printf 'source inherited insert exit=%s\nsource output=%s\n' "$source_insert_exit" "$source_insert_output"
printf 'destination inherited insert exit=%s\ndestination output=%s\n' "$destination_insert_exit" "$destination_insert_output"

if [[ "$source_inherit_before" != f || "$destination_inherit_before" != t || "$source_insert_exit" -eq 0 || "$destination_insert_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated membership INHERIT-option drift.' >&2
  exit 2
fi
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'delete from public.products where id=900;' >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_MEMBERSHIP_INHERIT_OPTION_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'inherit_option|membership.*inherit|role.*membership' <<<"$runtime_output"; then
    echo 'NEON_ROLE_MEMBERSHIP_INHERIT_OPTION_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_MEMBERSHIP_INHERIT_OPTION_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_inherit_after="$(inherit_option "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_insert_after_output="$(probe_insert "$DESTINATION_APP_URL" 901 2>&1)"; destination_insert_after_exit=$?
set -e
destination_probe_count="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products where id=901;")"

printf 'AFTER\ndestination membership inherit_option=%s\nappended source row=%s\n' "$destination_inherit_after" "$destination_row_2"
printf 'destination inherited insert exit=%s\ndestination output=%s\ndestination probe row count=%s\nNEON_ROLE_MEMBERSHIP_INHERIT_OPTION_DRIFT_SYNC_EXIT=%s\n' "$destination_insert_after_exit" "$destination_insert_after_output" "$destination_probe_count" "$sync_exit"

if [[ "$destination_inherit_after" == f && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_insert_after_exit" -ne 0 && "$destination_probe_count" == 0 ]]; then
  echo 'NEON_ROLE_MEMBERSHIP_INHERIT_OPTION_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_MEMBERSHIP_INHERIT_OPTION_DRIFT_DETECTED=false'
exit 1

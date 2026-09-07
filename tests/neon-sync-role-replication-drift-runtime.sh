#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' noreplication;"
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' replication;"
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

replication_flag() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolreplication from pg_roles where rolname='cycle_app';"
}
create_slot_as_app() {
  local url="$1"
  local slot="$2"
  psql "$url" -v ON_ERROR_STOP=1 -At -F '|' -c "select slot_name, lsn from pg_create_physical_replication_slot('$slot');"
}
slot_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_replication_slots where slot_name='$2';"
}

source_replication_before="$(replication_flag "$SOURCE_ADMIN_URL")"
destination_replication_before="$(replication_flag "$DESTINATION_ADMIN_URL")"
set +e
source_slot_output="$(create_slot_as_app "$SOURCE_APP_URL" cycle_probe_before 2>&1)"; source_slot_exit=$?
destination_slot_output="$(create_slot_as_app "$DESTINATION_APP_URL" cycle_probe_before 2>&1)"; destination_slot_exit=$?
set -e
source_slot_count="$(slot_count "$SOURCE_ADMIN_URL" cycle_probe_before)"
destination_slot_count="$(slot_count "$DESTINATION_ADMIN_URL" cycle_probe_before)"

printf 'BEFORE\nsource cycle_app rolreplication=%s\ndestination cycle_app rolreplication=%s\n' "$source_replication_before" "$destination_replication_before"
printf 'source cycle_app create replication slot exit=%s\nsource output=%s\nsource slot count=%s\n' "$source_slot_exit" "$source_slot_output" "$source_slot_count"
printf 'destination cycle_app create replication slot exit=%s\ndestination output=%s\ndestination slot count=%s\n' "$destination_slot_exit" "$destination_slot_output" "$destination_slot_count"

if [[ "$source_replication_before" != f || "$destination_replication_before" != t || "$source_slot_exit" -eq 0 || "$source_slot_count" != 0 || "$destination_slot_exit" -ne 0 || "$destination_slot_count" != 1 ]]; then
  echo 'Fixture did not establish isolated role REPLICATION drift.' >&2
  exit 2
fi

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "select pg_drop_replication_slot('cycle_probe_before');"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_REPLICATION_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'rolreplication|replication.*role|role.*replication' <<<"$runtime_output"; then
    echo 'NEON_ROLE_REPLICATION_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_REPLICATION_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_replication_after="$(replication_flag "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_slot_after_output="$(create_slot_as_app "$DESTINATION_APP_URL" cycle_probe_after 2>&1)"; destination_slot_after_exit=$?
set -e
destination_slot_after_count="$(slot_count "$DESTINATION_ADMIN_URL" cycle_probe_after)"

printf 'AFTER\ndestination cycle_app rolreplication=%s\nappended source row=%s\n' "$destination_replication_after" "$destination_row_2"
printf 'destination cycle_app create replication slot exit=%s\ndestination output=%s\ndestination slot count=%s\nNEON_ROLE_REPLICATION_DRIFT_SYNC_EXIT=%s\n' "$destination_slot_after_exit" "$destination_slot_after_output" "$destination_slot_after_count" "$sync_exit"

if [[ "$destination_replication_after" == f && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_slot_after_exit" -ne 0 && "$destination_slot_after_count" == 0 ]]; then
  echo 'NEON_ROLE_REPLICATION_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_REPLICATION_DRIFT_DETECTED=false'
echo 'Destination retained REPLICATION authority absent from the equivalent source application role.' >&2
exit 1

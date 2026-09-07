#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'app' nobypassrls;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'app' bypassrls;
create database cycle_d_destination;
SQL

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.tenant_records (
  id bigint primary key,
  tenant_id text not null,
  payload text not null
);
alter table public.tenant_records enable row level security;
create policy tenant_isolation on public.tenant_records
  for select to cycle_app
  using (tenant_id = current_setting('app.tenant_id', true));
grant usage on schema public to cycle_app;
grant select on public.tenant_records to cycle_app;
insert into public.tenant_records values
  (1, 'tenant-a', 'A-ONE'),
  (2, 'tenant-b', 'B-SECRET'),
  (3, 'tenant-a', 'A-THREE');
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.tenant_records (
  id bigint primary key,
  tenant_id text not null,
  payload text not null
);
alter table public.tenant_records enable row level security;
create policy tenant_isolation on public.tenant_records
  for select to cycle_app
  using (tenant_id = current_setting('app.tenant_id', true));
grant usage on schema public to cycle_app;
grant select on public.tenant_records to cycle_app;
insert into public.tenant_records values
  (1, 'tenant-a', 'A-ONE'),
  (2, 'tenant-b', 'B-SECRET');
SQL

role_bypassrls() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolbypassrls from pg_catalog.pg_roles where rolname='cycle_app';"
}
app_rows() {
  PGOPTIONS='-c app.tenant_id=tenant-a' psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,tenant_id,payload from public.tenant_records order by id;"
}

source_bypass_before="$(role_bypassrls "$SOURCE_ADMIN_URL")"
destination_bypass_before="$(role_bypassrls "$DESTINATION_ADMIN_URL")"
source_rows_before="$(app_rows "$SOURCE_APP_URL")"
destination_rows_before="$(app_rows "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource cycle_app rolbypassrls=%s\ndestination cycle_app rolbypassrls=%s\n' "$source_bypass_before" "$destination_bypass_before"
printf 'source cycle_app tenant-a rows=%s\ndestination cycle_app tenant-a rows=%s\n' "$source_rows_before" "$destination_rows_before"

if [[ "$source_bypass_before" != f || "$destination_bypass_before" != t ]]; then
  echo 'Fixture did not establish isolated BYPASSRLS role-attribute drift.' >&2
  exit 2
fi
if [[ "$source_rows_before" != $'1|tenant-a|A-ONE\n3|tenant-a|A-THREE' ]]; then
  echo 'Source RLS fixture did not filter tenant-b row as required.' >&2
  exit 2
fi
if [[ "$destination_rows_before" != $'1|tenant-a|A-ONE\n2|tenant-b|B-SECRET' ]]; then
  echo 'Destination BYPASSRLS fixture did not expose the cross-tenant row.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_BYPASSRLS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'bypassrls|role.*attribute|rls.*role.*(drift|mismatch|incompatib)' <<<"$runtime_output"; then
    echo 'NEON_ROLE_BYPASSRLS_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_BYPASSRLS_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_bypass_after="$(role_bypassrls "$DESTINATION_ADMIN_URL")"
destination_row_3="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,tenant_id,payload from public.tenant_records where id=3;")"
destination_rows_after="$(app_rows "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination cycle_app rolbypassrls=%s\nappended source row=%s\n' "$destination_bypass_after" "$destination_row_3"
printf 'destination cycle_app tenant-a rows=%s\nNEON_ROLE_BYPASSRLS_DRIFT_SYNC_EXIT=%s\n' "$destination_rows_after" "$sync_exit"

if [[ "$destination_bypass_after" == f && "$destination_row_3" == '3|tenant-a|A-THREE' && "$destination_rows_after" == $'1|tenant-a|A-ONE\n3|tenant-a|A-THREE' ]]; then
  echo 'NEON_ROLE_BYPASSRLS_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_BYPASSRLS_DRIFT_DETECTED=false'
echo 'Destination application role retained BYPASSRLS authority absent on source, exposing cross-tenant rows.' >&2
exit 1

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
alter role cycle_app set DateStyle = 'ISO, DMY';
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-app-password';
alter role cycle_app set DateStyle = 'ISO, MDY';
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'datestyle=%';"
}

probe_date_parse() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "show DateStyle; select '01/02/2026'::date;"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_date_parse "$SOURCE_APP_URL")"
destination_probe="$(probe_date_parse "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource date parse=%s\ndestination date parse=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"

if [[ "${source_setting,,}" != 'datestyle=iso, dmy' || "${destination_setting,,}" != 'datestyle=iso, mdy' ]]; then
  echo 'Fixture did not establish DateStyle drift.' >&2; exit 2
fi
if [[ "$source_probe" != *'ISO, DMY'* || "$source_probe" != *$'2026-02-01' ]]; then
  echo 'Source DMY application parse did not resolve ambiguous date to 2026-02-01.' >&2; exit 2
fi
if [[ "$destination_probe" != *'ISO, MDY'* || "$destination_probe" != *$'2026-01-02' ]]; then
  echo 'Destination MDY application parse did not resolve ambiguous date to 2026-01-02.' >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_DATESTYLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'datestyle|pg_db_role_setting|role setting|date style' <<<"$runtime_output"; then
    echo 'NEON_ROLE_DATESTYLE_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_DATESTYLE_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(probe_date_parse "$SOURCE_APP_URL")"
destination_probe_after="$(probe_date_parse "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource date parse=%s\ndestination date parse=%s\nNEON_ROLE_DATESTYLE_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$source_probe_after" "$destination_probe_after" "$sync_exit"

if [[ "${destination_setting_after,,}" == 'datestyle=iso, dmy' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == *'ISO, DMY'* && "$destination_probe_after" == *$'2026-02-01' ]]; then
  echo 'NEON_ROLE_DATESTYLE_DRIFT_DETECTED=true'; exit 0
fi
echo 'NEON_ROLE_DATESTYLE_DRIFT_DETECTED=false'
exit 1

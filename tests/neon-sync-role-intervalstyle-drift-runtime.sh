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
alter role cycle_app set IntervalStyle = postgres;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set IntervalStyle = sql_standard;
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
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'intervalstyle=%';"
}

probe_interval_output() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "show IntervalStyle; select interval '1 day 2 hours 3 minutes 4 seconds';"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_interval_output "$SOURCE_APP_URL")"
destination_probe="$(probe_interval_output "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource interval output=%s\ndestination interval output=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"

if [[ "${source_setting,,}" != 'intervalstyle=postgres' || "${destination_setting,,}" != 'intervalstyle=sql_standard' ]]; then
  echo 'Fixture did not establish IntervalStyle drift.' >&2; exit 2
fi
if [[ "$source_probe" != postgres$'\n'* || "$destination_probe" != sql_standard$'\n'* ]]; then
  echo 'Application probes did not execute under the intended IntervalStyle settings.' >&2; exit 2
fi
if [[ "$source_probe" == "$destination_probe" ]]; then
  echo 'Fixture did not establish an application-visible interval representation difference.' >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_INTERVALSTYLE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'intervalstyle|interval style|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_INTERVALSTYLE_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_INTERVALSTYLE_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(probe_interval_output "$SOURCE_APP_URL")"
destination_probe_after="$(probe_interval_output "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource interval output=%s\ndestination interval output=%s\nNEON_ROLE_INTERVALSTYLE_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$source_probe_after" "$destination_probe_after" "$sync_exit"

if [[ "${destination_setting_after,,}" == 'intervalstyle=postgres' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == "$source_probe_after" ]]; then
  echo 'NEON_ROLE_INTERVALSTYLE_DRIFT_DETECTED=true'; exit 0
fi
echo 'NEON_ROLE_INTERVALSTYLE_DRIFT_DETECTED=false'
exit 1

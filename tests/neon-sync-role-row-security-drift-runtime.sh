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
alter role cycle_app set row_security = on;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set row_security = off;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
alter table public.products enable row level security;
create policy cycle_app_visible_products on public.products for select to cycle_app using (quantity < 10);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'row_security=%';"
}

probe_app_read() {
  local url="$1" output code
  set +e
  output="$(psql "$url" -v ON_ERROR_STOP=1 -At -F '|' -c "show row_security; select id,sku,quantity from public.products order by id;" 2>&1)"
  code=$?
  set -e
  printf '%s|%s' "$code" "$(printf '%s' "$output" | tr '\n' '\036')"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_app_read "$SOURCE_APP_URL")"
destination_probe="$(probe_app_read "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app read=%s\ndestination app read=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"

if [[ "${source_setting,,}" != 'row_security=on' || "${destination_setting,,}" != 'row_security=off' ]]; then
  echo 'Fixture did not establish row_security drift.' >&2; exit 2
fi
if [[ "$source_probe" != 0\|on* || "$source_probe" != *'1|SOURCE-SKU-1|7'* || "$source_probe" == *'SOURCE-SKU-2'* ]]; then
  echo 'Source application probe did not enforce the intended RLS policy.' >&2; exit 2
fi
if [[ "$destination_probe" != 1\|off* || "$destination_probe" != *'query would be affected by row-level security policy'* ]]; then
  echo 'Destination application probe did not establish row_security=off fail-closed behavior.' >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ROW_SECURITY_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'row_security|row security|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_ROW_SECURITY_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_ROW_SECURITY_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(probe_app_read "$SOURCE_APP_URL")"
destination_probe_after="$(probe_app_read "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app read=%s\ndestination app read=%s\nNEON_ROLE_ROW_SECURITY_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$source_probe_after" "$destination_probe_after" "$sync_exit"

if [[ "${destination_setting_after,,}" == 'row_security=on' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == "$source_probe_after" ]]; then
  echo 'NEON_ROLE_ROW_SECURITY_DRIFT_DETECTED=true'; exit 0
fi
echo 'NEON_ROLE_ROW_SECURITY_DRIFT_DETECTED=false'
exit 1

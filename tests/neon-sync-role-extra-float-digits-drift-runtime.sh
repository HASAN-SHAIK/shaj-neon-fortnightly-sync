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
alter role cycle_app set extra_float_digits = 3;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set extra_float_digits = -3;
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
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'extra_float_digits=%';"
}

probe_float() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c "show extra_float_digits; select (1.2345678901234567::double precision)::text; select id,sku,quantity from public.products where id=1;"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_float "$SOURCE_APP_URL")"
destination_probe="$(probe_float "$DESTINATION_APP_URL")"
source_float="$(printf '%s\n' "$source_probe" | sed -n '2p')"
destination_float="$(printf '%s\n' "$destination_probe" | sed -n '2p')"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app float probe=%s\ndestination app float probe=%s\n' "$source_setting" "$destination_setting" "$(printf '%s' "$source_probe" | tr '\n' '\036')" "$(printf '%s' "$destination_probe" | tr '\n' '\036')"

if [[ "${source_setting,,}" != 'extra_float_digits=3' || "${destination_setting,,}" != 'extra_float_digits=-3' ]]; then
  echo 'Fixture did not establish extra_float_digits drift.' >&2; exit 2
fi
if [[ "$source_probe" != *'1|SOURCE-SKU-1|7'* || "$destination_probe" != *'1|SOURCE-SKU-1|7'* ]]; then
  echo 'Application product-row probe failed.' >&2; exit 2
fi
if [[ -z "$source_float" || -z "$destination_float" || "$source_float" == "$destination_float" ]]; then
  echo 'Fixture did not establish distinct float text serialization.' >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_EXTRA_FLOAT_DIGITS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'extra_float_digits|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_EXTRA_FLOAT_DIGITS_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_EXTRA_FLOAT_DIGITS_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(probe_float "$SOURCE_APP_URL")"
destination_probe_after="$(probe_float "$DESTINATION_APP_URL")"
source_float_after="$(printf '%s\n' "$source_probe_after" | sed -n '2p')"
destination_float_after="$(printf '%s\n' "$destination_probe_after" | sed -n '2p')"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app float probe=%s\ndestination app float probe=%s\nNEON_ROLE_EXTRA_FLOAT_DIGITS_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$(printf '%s' "$source_probe_after" | tr '\n' '\036')" "$(printf '%s' "$destination_probe_after" | tr '\n' '\036')" "$sync_exit"

if [[ "${destination_setting_after,,}" == 'extra_float_digits=3' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_float_after" == "$destination_float_after" ]]; then
  echo 'NEON_ROLE_EXTRA_FLOAT_DIGITS_DRIFT_DETECTED=true'; exit 0
fi
echo 'NEON_ROLE_EXTRA_FLOAT_DIGITS_DRIFT_DETECTED=false'
exit 1

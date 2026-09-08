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
alter role cycle_app set bytea_output = hex;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set bytea_output = escape;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.binary_payloads (id bigint primary key, payload bytea not null);
grant usage on schema public to cycle_app;
grant select on public.products, public.binary_payloads to cycle_app;
insert into public.binary_payloads values (1, decode('005c41ff','hex'));
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'bytea_output=%';"
}

probe_bytea() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c "show bytea_output; select id,payload from public.binary_payloads where id=1; select id,sku,quantity from public.products where id=1;"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_bytea "$SOURCE_APP_URL")"
destination_probe="$(probe_bytea "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app bytea probe=%s\ndestination app bytea probe=%s\n' "$source_setting" "$destination_setting" "$(printf '%s' "$source_probe" | tr '\n' '\036')" "$(printf '%s' "$destination_probe" | tr '\n' '\036')"

if [[ "${source_setting,,}" != 'bytea_output=hex' || "${destination_setting,,}" != 'bytea_output=escape' ]]; then
  echo 'Fixture did not establish bytea_output drift.' >&2; exit 2
fi
if [[ "$source_probe" != *'hex'* || "$source_probe" != *'1|\x005c41ff'* || "$source_probe" != *'1|SOURCE-SKU-1|7'* ]]; then
  echo 'Source application probe did not establish expected hex bytea output.' >&2; exit 2
fi
if [[ "$destination_probe" != *'escape'* || "$destination_probe" == *'1|\x005c41ff'* || "$destination_probe" != *'1|SOURCE-SKU-1|7'* ]]; then
  echo 'Destination application probe did not establish distinct escape bytea output.' >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_BYTEA_OUTPUT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'bytea_output|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_BYTEA_OUTPUT_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_BYTEA_OUTPUT_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(probe_bytea "$SOURCE_APP_URL")"
destination_probe_after="$(probe_bytea "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app bytea probe=%s\ndestination app bytea probe=%s\nNEON_ROLE_BYTEA_OUTPUT_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$(printf '%s' "$source_probe_after" | tr '\n' '\036')" "$(printf '%s' "$destination_probe_after" | tr '\n' '\036')" "$sync_exit"

if [[ "${destination_setting_after,,}" == 'bytea_output=hex' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == *'1|\x005c41ff'* ]]; then
  echo 'NEON_ROLE_BYTEA_OUTPUT_DRIFT_DETECTED=true'; exit 0
fi
echo 'NEON_ROLE_BYTEA_OUTPUT_DRIFT_DETECTED=false'
exit 1

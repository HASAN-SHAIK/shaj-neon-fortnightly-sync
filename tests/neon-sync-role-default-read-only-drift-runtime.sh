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
alter role cycle_app set default_transaction_read_only = on;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-app-password';
alter role cycle_app set default_transaction_read_only = off;
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
grant select, insert on public.products to cycle_app;
SQL
done

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select coalesce(array_to_string(setconfig,','),'') from pg_db_role_setting s join pg_roles r on r.oid=s.setrole where r.rolname='cycle_app' and s.setdatabase=0;"
}

probe_insert() {
  local url="$1"
  local id="$2"
  set +e
  local output
  output="$(psql "$url" -v ON_ERROR_STOP=1 -At -c "insert into public.products values ($id,'APP-PROBE',1) returning id;" 2>&1)"
  local code=$?
  set -e
  printf '%s|%s\n' "$code" "$output"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_insert "$SOURCE_APP_URL" 900)"
destination_probe="$(probe_insert "$DESTINATION_APP_URL" 901)"

printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\n' "$source_setting" "$destination_setting"
printf 'source app insert=%s\ndestination app insert=%s\n' "$source_probe" "$destination_probe"

if [[ "$source_setting" != 'default_transaction_read_only=on' || "$destination_setting" != 'default_transaction_read_only=off' ]]; then
  echo 'Fixture did not establish role default_transaction_read_only drift.' >&2
  exit 2
fi
if [[ "$source_probe" != 1\|* || "$source_probe" != *'cannot execute INSERT in a read-only transaction'* ]]; then
  echo 'Source application role did not fail read-only as expected.' >&2
  exit 2
fi
if [[ "$destination_probe" != 0\|* || "$destination_probe" != *'901'* ]]; then
  echo 'Destination application role did not demonstrate writable state.' >&2
  exit 2
fi
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "delete from public.products where id=901;" >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_DEFAULT_READ_ONLY_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'default_transaction_read_only|pg_db_role_setting|read.only|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_DEFAULT_READ_ONLY_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_DEFAULT_READ_ONLY_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_probe_after="$(probe_insert "$DESTINATION_APP_URL" 902)"

printf 'AFTER\ndestination role setting=%s\nappended source row=%s\ndestination app insert=%s\nNEON_ROLE_DEFAULT_READ_ONLY_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$destination_probe_after" "$sync_exit"

if [[ "$destination_setting_after" == 'default_transaction_read_only=on' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == 1\|* && "$destination_probe_after" == *'cannot execute INSERT in a read-only transaction'* ]]; then
  echo 'NEON_ROLE_DEFAULT_READ_ONLY_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_DEFAULT_READ_ONLY_DRIFT_DETECTED=false'
exit 1

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
alter role cycle_app set default_transaction_isolation = 'serializable';
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-app-password';
alter role cycle_app set default_transaction_isolation = 'read committed';
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
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and cfg like 'default_transaction_isolation=%';"
}

probe_isolation() {
  local app_url="$1"
  local admin_url="$2"
  local probe_id="$3"
  local out_file
  out_file="$(mktemp)"
  set +e
  psql "$app_url" -v ON_ERROR_STOP=1 -At >"$out_file" 2>&1 <<'SQL' &
begin;
show transaction_isolation;
select count(*) from public.products where id < 1000;
select pg_sleep(0.6);
select count(*) from public.products where id < 1000;
commit;
SQL
  local app_pid=$!
  set -e
  sleep 0.2
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "insert into public.products values ($probe_id,'CONCURRENT-PROBE',1);" >/dev/null
  set +e
  wait "$app_pid"
  local code=$?
  set -e
  local output
  output="$(cat "$out_file")"
  rm -f "$out_file"
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "delete from public.products where id=$probe_id;" >/dev/null
  output="${output//$'\n'/\\n}"
  printf '%s|%s\n' "$code" "$output"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_isolation "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" 901)"
destination_probe="$(probe_isolation "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" 901)"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource isolation probe=%s\ndestination isolation probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"

if [[ "$source_setting" != 'default_transaction_isolation=serializable' || "$destination_setting" != 'default_transaction_isolation=read committed' ]]; then
  echo 'Fixture did not establish default transaction isolation drift.' >&2; exit 2
fi
if [[ "$source_probe" != 0\|*serializable* || "$source_probe" != *'2\\n\\n2'* ]]; then
  echo 'Source serializable transaction did not preserve its initial snapshot across the concurrent insert.' >&2; exit 2
fi
if [[ "$destination_probe" != 0\|*'read committed'* || "$destination_probe" != *'1\\n\\n2'* ]]; then
  echo 'Destination read-committed transaction did not observe the concurrent insert on its second statement.' >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_DEFAULT_ISOLATION_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'default_transaction_isolation|pg_db_role_setting|role setting|isolation' <<<"$runtime_output"; then
    echo 'NEON_ROLE_DEFAULT_ISOLATION_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_DEFAULT_ISOLATION_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(probe_isolation "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" 902)"
destination_probe_after="$(probe_isolation "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" 902)"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource isolation probe=%s\ndestination isolation probe=%s\nNEON_ROLE_DEFAULT_ISOLATION_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$source_probe_after" "$destination_probe_after" "$sync_exit"

if [[ "$destination_setting_after" == 'default_transaction_isolation=serializable' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after" == 0\|*serializable* && "$destination_probe_after" == *'2\\n\\n2'* ]]; then
  echo 'NEON_ROLE_DEFAULT_ISOLATION_DRIFT_DETECTED=true'; exit 0
fi
echo 'NEON_ROLE_DEFAULT_ISOLATION_DRIFT_DETECTED=false'
exit 1

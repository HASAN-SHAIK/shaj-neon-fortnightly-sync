#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login;"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

setup_db() {
  local admin_url="$1" application_name="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v application_name="$application_name" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, application_name %L)', current_database(), :'application_name') \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name 'public', table_name 'products');
grant select on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" shaj_source_fdw
setup_db "$DESTINATION_ADMIN_URL" shaj_destination_fdw
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_application_name_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='application_name';"
}

application_name_probe() {
  local app_url="$1" admin_url="$2" expected_name="$3" expected_rows="$4"
  local probe_file
  probe_file="$(mktemp)"

  psql "$app_url" -v ON_ERROR_STOP=1 -At <<'SQL' >"$probe_file" 2>&1 &
select count(*) from public.products_remote;
select pg_sleep(6);
SQL
  local app_pid=$!

  local connection_count=0
  for _ in $(seq 1 30); do
    connection_count="$(psql "$admin_url" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_stat_activity where datname=current_database() and usename='cycle_app' and application_name='$expected_name';")"
    if [[ "$connection_count" == 1 ]]; then
      break
    fi
    sleep 0.2
  done

  set +e
  wait "$app_pid"
  local app_exit=$?
  set -e
  local app_output
  app_output="$(cat "$probe_file")"
  rm -f "$probe_file"

  if [[ "$app_exit" -ne 0 ]]; then
    printf 'application probe failed for %s: %s\n' "$expected_name" "$app_output" >&2
    return 2
  fi

  local observed_rows
  observed_rows="$(head -n 1 <<<"$app_output")"
  if [[ "$observed_rows" != "$expected_rows" || "$connection_count" != 1 ]]; then
    printf 'application probe mismatch for %s: rows=%s connection_count=%s output=%s\n' "$expected_name" "$observed_rows" "$connection_count" "$app_output" >&2
    return 2
  fi

  printf '%s|%s\n' "$observed_rows" "$connection_count"
}

source_option_before="$(server_application_name_option "$SOURCE_ADMIN_URL")"
destination_option_before="$(server_application_name_option "$DESTINATION_ADMIN_URL")"
source_probe_before="$(application_name_probe "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" shaj_source_fdw 1)"
destination_probe_before="$(application_name_probe "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" shaj_destination_fdw 1)"

printf 'BEFORE\nsource foreign server application_name=%s\ndestination foreign server application_name=%s\n' "$source_option_before" "$destination_option_before"
printf 'source application/pg_stat_activity probe=%s\ndestination application/pg_stat_activity probe=%s\n' "$source_probe_before" "$destination_probe_before"

if [[ "$source_option_before" != shaj_source_fdw || "$destination_option_before" != shaj_destination_fdw || "$source_probe_before" != '1|1' || "$destination_probe_before" != '1|1' ]]; then
  echo 'Fixture did not establish isolated foreign-server application_name runtime drift.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_APPLICATION_NAME_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(application_name|application name|option|incompatib|drift|mismatch)|(application_name|application name|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_APPLICATION_NAME_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_APPLICATION_NAME_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_option_after="$(server_application_name_option "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_probe_after="$(application_name_probe "$SOURCE_APP_URL" "$SOURCE_ADMIN_URL" shaj_source_fdw 2)"
destination_probe_after="$(application_name_probe "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" shaj_destination_fdw 2)"

printf 'AFTER\ndestination foreign server application_name=%s\nappended source row=%s\n' "$destination_option_after" "$destination_row_2"
printf 'source application/pg_stat_activity probe=%s\ndestination application/pg_stat_activity probe=%s\n' "$source_probe_after" "$destination_probe_after"
printf 'NEON_FOREIGN_SERVER_APPLICATION_NAME_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_option_after" == shaj_source_fdw && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_probe_after" == '2|1' ]]; then
  if destination_converged_probe="$(application_name_probe "$DESTINATION_APP_URL" "$DESTINATION_ADMIN_URL" shaj_source_fdw 2)" && [[ "$destination_converged_probe" == '2|1' ]]; then
    echo 'NEON_FOREIGN_SERVER_APPLICATION_NAME_DRIFT_DETECTED=true'
    exit 0
  fi
fi

if [[ "$destination_option_after" == shaj_destination_fdw && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_probe_after" == '2|1' && "$destination_probe_after" == '2|1' ]]; then
  echo 'NEON_FOREIGN_SERVER_APPLICATION_NAME_DRIFT_DETECTED=false'
  echo 'Destination retained a different postgres_fdw application_name; production synchronization succeeded while the real remote-session identity in pg_stat_activity remained different from source.' >&2
  exit 1
fi

echo 'Post-sync foreign-server application_name scenario produced an unexpected runtime state.' >&2
exit 2

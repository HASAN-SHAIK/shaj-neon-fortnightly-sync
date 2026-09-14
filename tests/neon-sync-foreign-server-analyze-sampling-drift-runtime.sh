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
  local admin_url="$1" dbname="$2" sampling="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v sampling="$sampling" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create table public.sample_remote(id integer primary key, quantity integer not null, payload text not null);
insert into public.sample_remote
select g, (g % 97), repeat('x', 64)
from generate_series(1,100000) g;
grant usage on schema public to cycle_app;
grant select on public.sample_remote to cycle_app;
select format('create server retail_sampling foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, analyze_sampling %L)', :'dbname', :'sampling') \gexec
create user mapping for cycle_app server retail_sampling options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_sampling options (user 'postgres', password_required 'false');
grant usage on foreign server retail_sampling to cycle_app;
create foreign table public.sample_remote_fdw(id integer, quantity integer, payload text)
  server retail_sampling options (schema_name 'public', table_name 'sample_remote');
alter foreign table public.sample_remote_fdw owner to cycle_app;
alter system set log_statement = 'all';
select pg_reload_conf();
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source system
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination off
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_sampling() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_sampling')) where option_name='analyze_sampling';"
}

app_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select count(*),coalesce(sum(quantity),0) from public.sample_remote_fdw;"
}

container_for_port() {
  docker ps --filter "publish=$1" --format '{{.ID}}' | head -n1
}

analyze_probe() {
  local app_url="$1" port="$2" container before after fresh
  container="$(container_for_port "$port")"
  if [[ -z "$container" ]]; then
    return 2
  fi
  before="$(docker logs "$container" 2>&1 | wc -l | tr -d ' ')"
  psql "$app_url" -v ON_ERROR_STOP=1 -c 'analyze public.sample_remote_fdw;' >/dev/null
  sleep 0.15
  after="$(docker logs "$container" 2>&1 | wc -l | tr -d ' ')"
  if (( after <= before )); then
    return 2
  fi
  fresh="$(docker logs "$container" 2>&1 | tail -n +$((before + 1)))"
  printf '%s\n' "$fresh" | grep -E 'statement: .*sample_remote|STATEMENT: .*sample_remote' | grep -v -E 'ANALYZE .*sample_remote_fdw' || true
}

has_remote_sampling_cardinality_probe() {
  grep -Eqi "SELECT reltuples, relkind FROM pg_catalog.pg_class WHERE oid = 'public.sample_remote'::pg_catalog.regclass" <<<"$1"
}

source_option_before="$(server_sampling "$SOURCE_ADMIN_URL")"
destination_option_before="$(server_sampling "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_read "$SOURCE_APP_URL")"
destination_read_before="$(app_read "$DESTINATION_APP_URL")"
source_probe_before="$(analyze_probe "$SOURCE_APP_URL" 55432)"
destination_probe_before="$(analyze_probe "$DESTINATION_APP_URL" 55433)"

printf 'BEFORE\nsource analyze_sampling=%s\ndestination analyze_sampling=%s\n' "$source_option_before" "$destination_option_before"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_before" "$destination_read_before"
printf 'SOURCE REMOTE ANALYZE LOG\n%s\nDESTINATION REMOTE ANALYZE LOG\n%s\n' "$source_probe_before" "$destination_probe_before"

if [[ "$source_option_before" != system || "$destination_option_before" != off || "$source_read_before" != '100000|4799775' || "$destination_read_before" != '100000|4799775' ]]; then
  echo 'Fixture did not establish isolated analyze_sampling drift with equivalent application data.' >&2
  exit 2
fi

# PostgreSQL 18.6's observed postgres_fdw protocol for analyze_sampling=system
# obtains remote relation cardinality (reltuples/relkind) before opening the
# sampling cursor. analyze_sampling=off skips that remote sampling-cardinality
# probe and transfers the table for local sampling. Assert the real protocol
# distinction rather than assuming TABLESAMPLE text must appear in server logs.
if [[ -z "$source_probe_before" || -z "$destination_probe_before" ]] || ! has_remote_sampling_cardinality_probe "$source_probe_before" || has_remote_sampling_cardinality_probe "$destination_probe_before"; then
  echo 'Fixture did not establish observable PostgreSQL 18 remote ANALYZE protocol divergence.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" EXCLUDED_TABLES='public.sample_remote' bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_ANALYZE_SAMPLING_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(analyze_sampling|analyze sampling|option|incompatib|drift|mismatch)|(analyze_sampling|analyze sampling|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_ANALYZE_SAMPLING_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_ANALYZE_SAMPLING_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_option_after="$(server_sampling "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_read_after="$(app_read "$SOURCE_APP_URL")"
destination_read_after="$(app_read "$DESTINATION_APP_URL")"
source_probe_after="$(analyze_probe "$SOURCE_APP_URL" 55432)"
destination_probe_after="$(analyze_probe "$DESTINATION_APP_URL" 55433)"

printf 'AFTER\ndestination analyze_sampling=%s\nappended source row=%s\n' "$destination_option_after" "$destination_row_2"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_after" "$destination_read_after"
printf 'SOURCE REMOTE ANALYZE LOG AFTER\n%s\nDESTINATION REMOTE ANALYZE LOG AFTER\n%s\n' "$source_probe_after" "$destination_probe_after"
printf 'NEON_FOREIGN_SERVER_ANALYZE_SAMPLING_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_option_after" == system && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '100000|4799775' && "$destination_read_after" == '100000|4799775' && -n "$destination_probe_after" ]] && has_remote_sampling_cardinality_probe "$destination_probe_after"; then
  echo 'NEON_FOREIGN_SERVER_ANALYZE_SAMPLING_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_option_after" == off && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '100000|4799775' && "$destination_read_after" == '100000|4799775' && -n "$source_probe_after" && -n "$destination_probe_after" ]] && has_remote_sampling_cardinality_probe "$source_probe_after" && ! has_remote_sampling_cardinality_probe "$destination_probe_after"; then
  echo 'NEON_FOREIGN_SERVER_ANALYZE_SAMPLING_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_ANALYZE_SAMPLING_REMOTE_SQL_DIVERGENCE=true'
  echo 'Destination retained analyze_sampling=off; production synchronization succeeded while ANALYZE continued using a different PostgreSQL 18 remote sampling protocol from source.' >&2
  exit 1
fi

echo 'Post-sync foreign-server analyze_sampling scenario produced an unexpected runtime state.' >&2
exit 2

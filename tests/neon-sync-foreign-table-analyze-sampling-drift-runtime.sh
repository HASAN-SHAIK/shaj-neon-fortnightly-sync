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
select format('create server retail_sampling foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L)', :'dbname') \gexec
create user mapping for cycle_app server retail_sampling options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_sampling options (user 'postgres', password_required 'false');
grant usage on foreign server retail_sampling to cycle_app;
select format('create foreign table public.sample_remote_fdw(id integer, quantity integer, payload text) server retail_sampling options (schema_name ''public'', table_name ''sample_remote'', analyze_sampling %L)', :'sampling') \gexec
alter foreign table public.sample_remote_fdw owner to cycle_app;
alter system set log_statement = 'all';
select pg_reload_conf();
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source system
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination off
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

table_sampling() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select ftoptions from pg_foreign_table ft join pg_class c on c.oid=ft.ftrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='sample_remote_fdw')) where option_name='analyze_sampling';"
}

server_sampling() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select coalesce((select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_sampling')) where option_name='analyze_sampling'), '<absent>');"
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

source_table_before="$(table_sampling "$SOURCE_ADMIN_URL")"
destination_table_before="$(table_sampling "$DESTINATION_ADMIN_URL")"
source_server_before="$(server_sampling "$SOURCE_ADMIN_URL")"
destination_server_before="$(server_sampling "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_read "$SOURCE_APP_URL")"
destination_read_before="$(app_read "$DESTINATION_APP_URL")"
source_probe_before="$(analyze_probe "$SOURCE_APP_URL" 55432)"
destination_probe_before="$(analyze_probe "$DESTINATION_APP_URL" 55433)"

printf 'BEFORE\nsource table analyze_sampling=%s\ndestination table analyze_sampling=%s\n' "$source_table_before" "$destination_table_before"
printf 'source server analyze_sampling=%s\ndestination server analyze_sampling=%s\n' "$source_server_before" "$destination_server_before"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_before" "$destination_read_before"
printf 'SOURCE REMOTE ANALYZE LOG\n%s\nDESTINATION REMOTE ANALYZE LOG\n%s\n' "$source_probe_before" "$destination_probe_before"

if [[ "$source_table_before" != system || "$destination_table_before" != off || "$source_server_before" != '<absent>' || "$destination_server_before" != '<absent>' || "$source_read_before" != '100000|4799775' || "$destination_read_before" != '100000|4799775' ]]; then
  echo 'Fixture did not establish isolated table-level analyze_sampling drift with equal server policy and equivalent application data.' >&2
  exit 2
fi

if [[ -z "$source_probe_before" || -z "$destination_probe_before" ]] || ! has_remote_sampling_cardinality_probe "$source_probe_before" || has_remote_sampling_cardinality_probe "$destination_probe_before"; then
  echo 'Fixture did not establish observable PostgreSQL 18 table-level ANALYZE protocol divergence.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" EXCLUDED_TABLES='public.sample_remote' bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_TABLE_ANALYZE_SAMPLING_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign table.*(analyze_sampling|analyze sampling|option|incompatib|drift|mismatch)|(analyze_sampling|analyze sampling|option|drift|mismatch).*foreign table' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_TABLE_ANALYZE_SAMPLING_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_TABLE_ANALYZE_SAMPLING_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_table_after="$(table_sampling "$DESTINATION_ADMIN_URL")"
destination_server_after="$(server_sampling "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_read_after="$(app_read "$SOURCE_APP_URL")"
destination_read_after="$(app_read "$DESTINATION_APP_URL")"
source_probe_after="$(analyze_probe "$SOURCE_APP_URL" 55432)"
destination_probe_after="$(analyze_probe "$DESTINATION_APP_URL" 55433)"

printf 'AFTER\ndestination table analyze_sampling=%s\ndestination server analyze_sampling=%s\nappended source row=%s\n' "$destination_table_after" "$destination_server_after" "$destination_row_2"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_after" "$destination_read_after"
printf 'SOURCE REMOTE ANALYZE LOG AFTER\n%s\nDESTINATION REMOTE ANALYZE LOG AFTER\n%s\n' "$source_probe_after" "$destination_probe_after"
printf 'NEON_FOREIGN_TABLE_ANALYZE_SAMPLING_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_table_after" == system && "$destination_server_after" == '<absent>' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '100000|4799775' && "$destination_read_after" == '100000|4799775' && -n "$destination_probe_after" ]] && has_remote_sampling_cardinality_probe "$destination_probe_after"; then
  echo 'NEON_FOREIGN_TABLE_ANALYZE_SAMPLING_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_table_after" == off && "$destination_server_after" == '<absent>' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '100000|4799775' && "$destination_read_after" == '100000|4799775' && -n "$source_probe_after" && -n "$destination_probe_after" ]] && has_remote_sampling_cardinality_probe "$source_probe_after" && ! has_remote_sampling_cardinality_probe "$destination_probe_after"; then
  echo 'NEON_FOREIGN_TABLE_ANALYZE_SAMPLING_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_TABLE_ANALYZE_SAMPLING_REMOTE_SQL_DIVERGENCE=true'
  echo 'Destination retained table-level analyze_sampling=off; production synchronization succeeded while ANALYZE continued using a different PostgreSQL 18 remote sampling protocol from source.' >&2
  exit 1
fi

echo 'Post-sync foreign-table analyze_sampling scenario produced an unexpected runtime state.' >&2
exit 2

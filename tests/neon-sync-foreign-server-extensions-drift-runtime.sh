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
  local admin_url="$1" dbname="$2" source_extensions="$3"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v dbname="$dbname" -v source_extensions="$source_extensions" <<'SQL'
create extension postgres_fdw;
create extension hstore;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create table public.remote_docs(id bigint primary key, attrs hstore not null);
insert into public.remote_docs
select g,
       case when g % 10 = 0
            then hstore(array['priority','category'], array['yes','retail'])
            else hstore(array['category'], array['retail'])
       end
from generate_series(1,200) g;
grant usage on schema public to cycle_app;
grant select on public.remote_docs to cycle_app;

\if :source_extensions
select format(
  'create server retail_ext foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, extensions ''hstore'')',
  :'dbname'
) \gexec
\else
select format(
  'create server retail_ext foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L)',
  :'dbname'
) \gexec
\endif

create user mapping for cycle_app server retail_ext options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_ext options (user 'postgres', password_required 'false');
create foreign table public.docs_remote(id bigint, attrs hstore)
  server retail_ext options (schema_name 'public', table_name 'remote_docs');
grant select on public.docs_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_d_source true
setup_db "$DESTINATION_ADMIN_URL" cycle_d_destination false
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_extensions() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select coalesce((select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_ext')) where option_name='extensions'),'<absent>');"
}
app_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select count(*) from public.docs_remote where attrs ? 'priority';"
}
app_plan() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "explain (verbose, costs off) select count(*) from public.docs_remote where attrs ? 'priority';"
}
plan_remote_where() {
  grep -E 'Remote SQL:.*WHERE' <<<"$1" >/dev/null
}
plan_local_filter() {
  grep -E 'Filter:.*\?' <<<"$1" >/dev/null
}

source_option_before="$(server_extensions "$SOURCE_ADMIN_URL")"
destination_option_before="$(server_extensions "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_read "$SOURCE_APP_URL")"
destination_read_before="$(app_read "$DESTINATION_APP_URL")"
source_plan_before="$(app_plan "$SOURCE_APP_URL")"
destination_plan_before="$(app_plan "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource foreign server extensions=%s\ndestination foreign server extensions=%s\n' "$source_option_before" "$destination_option_before"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_before" "$destination_read_before"
printf 'SOURCE PLAN\n%s\nDESTINATION PLAN\n%s\n' "$source_plan_before" "$destination_plan_before"

source_remote_where=false
source_local_filter=false
destination_remote_where=false
destination_local_filter=false
plan_remote_where "$source_plan_before" && source_remote_where=true || true
plan_local_filter "$source_plan_before" && source_local_filter=true || true
plan_remote_where "$destination_plan_before" && destination_remote_where=true || true
plan_local_filter "$destination_plan_before" && destination_local_filter=true || true

if [[ "$source_option_before" != hstore || "$destination_option_before" != '<absent>' || "$source_read_before" != 20 || "$destination_read_before" != 20 || "$source_remote_where" != true || "$source_local_filter" != false || "$destination_remote_where" != false || "$destination_local_filter" != true ]]; then
  echo 'Fixture did not establish isolated foreign-server extensions drift with observable predicate-pushdown divergence.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_EXTENSIONS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(extensions|option|incompatib|drift|mismatch)|(extensions|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_EXTENSIONS_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_EXTENSIONS_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_option_after="$(server_extensions "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
source_read_after="$(app_read "$SOURCE_APP_URL")"
destination_read_after="$(app_read "$DESTINATION_APP_URL")"
source_plan_after="$(app_plan "$SOURCE_APP_URL")"
destination_plan_after="$(app_plan "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination foreign server extensions=%s\nappended source row=%s\n' "$destination_option_after" "$destination_row_2"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_after" "$destination_read_after"
printf 'SOURCE PLAN AFTER\n%s\nDESTINATION PLAN AFTER\n%s\n' "$source_plan_after" "$destination_plan_after"
printf 'NEON_FOREIGN_SERVER_EXTENSIONS_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

source_remote_where_after=false
source_local_filter_after=false
destination_remote_where_after=false
destination_local_filter_after=false
plan_remote_where "$source_plan_after" && source_remote_where_after=true || true
plan_local_filter "$source_plan_after" && source_local_filter_after=true || true
plan_remote_where "$destination_plan_after" && destination_remote_where_after=true || true
plan_local_filter "$destination_plan_after" && destination_local_filter_after=true || true

if [[ "$destination_option_after" == hstore && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == 20 && "$destination_read_after" == 20 && "$source_remote_where_after" == true && "$source_local_filter_after" == false && "$destination_remote_where_after" == true && "$destination_local_filter_after" == false ]]; then
  echo 'NEON_FOREIGN_SERVER_EXTENSIONS_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_option_after" == '<absent>' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == 20 && "$destination_read_after" == 20 && "$source_remote_where_after" == true && "$source_local_filter_after" == false && "$destination_remote_where_after" == false && "$destination_local_filter_after" == true ]]; then
  echo 'NEON_FOREIGN_SERVER_EXTENSIONS_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_EXTENSIONS_PUSHDOWN_DIVERGENCE=true'
  echo 'Destination retained no hstore extension shippability declaration; production synchronization succeeded while identical application results used different local-vs-remote predicate execution.' >&2
  exit 1
fi

echo 'Post-sync foreign-server extensions scenario produced an unexpected runtime state.' >&2
exit 2

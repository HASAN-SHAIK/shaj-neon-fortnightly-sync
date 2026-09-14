#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SOURCE_REMOTE_A_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source_a'
SOURCE_REMOTE_B_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source_b'
DESTINATION_REMOTE_A_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination_a'
DESTINATION_REMOTE_B_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination_b'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c 'create role cycle_app login;'
done
for db in cycle_d_source cycle_d_source_a cycle_d_source_b; do
  psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c "create database ${db};"
done
for db in cycle_d_destination cycle_d_destination_a cycle_d_destination_b; do
  psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c "create database ${db};"
done

setup_remote() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.remote_items(id bigint primary key, note text not null);
grant usage on schema public to cycle_app;
grant select, insert, delete on public.remote_items to cycle_app;
SQL
}

for url in "$SOURCE_REMOTE_A_URL" "$SOURCE_REMOTE_B_URL" "$DESTINATION_REMOTE_A_URL" "$DESTINATION_REMOTE_B_URL"; do
  setup_remote "$url"
done

setup_main() {
  local admin_url="$1" remote_a_db="$2" remote_b_db="$3" parallel_abort="$4"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v remote_a_db="$remote_a_db" -v remote_b_db="$remote_b_db" -v pa="$parallel_abort" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_pa_a foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, parallel_abort %L)', :'remote_a_db', :'pa') \gexec
select format('create server retail_pa_b foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, parallel_abort %L)', :'remote_b_db', :'pa') \gexec
create user mapping for cycle_app server retail_pa_a options (user 'cycle_app', password_required 'false');
create user mapping for cycle_app server retail_pa_b options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_pa_a options (user 'postgres', password_required 'false');
create user mapping for postgres server retail_pa_b options (user 'postgres', password_required 'false');
create foreign table public.pa_a(id bigint, note text) server retail_pa_a options (schema_name 'public', table_name 'remote_items');
create foreign table public.pa_b(id bigint, note text) server retail_pa_b options (schema_name 'public', table_name 'remote_items');
grant select, insert on public.pa_a, public.pa_b to cycle_app;
SQL
}

setup_main "$SOURCE_ADMIN_URL" cycle_d_source_a cycle_d_source_b true
setup_main "$DESTINATION_ADMIN_URL" cycle_d_destination_a cycle_d_destination_b false
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_parallel_options() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select string_agg(s.srvname || '=' || o.option_value, ',' order by s.srvname) from pg_foreign_server s cross join lateral pg_options_to_table(s.srvoptions) o where s.srvname in ('retail_pa_a','retail_pa_b') and o.option_name='parallel_abort';"
}

app_product_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c 'select count(*),coalesce(sum(quantity),0) from public.products;'
}

rollback_probe() {
  local app_url="$1" remote_a_url="$2" remote_b_url="$3" probe_id="$4" label="$5"
  local inside after_a after_b
  inside="$(psql "$app_url" -v ON_ERROR_STOP=1 -qAt -F '|' <<SQL
begin;
insert into public.pa_a values (${probe_id}, '${label}-a');
insert into public.pa_b values (${probe_id}, '${label}-b');
select (select count(*) from public.pa_a where id=${probe_id}), (select count(*) from public.pa_b where id=${probe_id});
rollback;
SQL
)"
  after_a="$(psql "$remote_a_url" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.remote_items where id=${probe_id};")"
  after_b="$(psql "$remote_b_url" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.remote_items where id=${probe_id};")"
  printf '%s|%s|%s' "$inside" "$after_a" "$after_b"
}

source_options_before="$(server_parallel_options "$SOURCE_ADMIN_URL")"
destination_options_before="$(server_parallel_options "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_product_read "$SOURCE_APP_URL")"
destination_read_before="$(app_product_read "$DESTINATION_APP_URL")"
source_abort_before="$(rollback_probe "$SOURCE_APP_URL" "$SOURCE_REMOTE_A_URL" "$SOURCE_REMOTE_B_URL" 90001 SOURCE-BEFORE)"
destination_abort_before="$(rollback_probe "$DESTINATION_APP_URL" "$DESTINATION_REMOTE_A_URL" "$DESTINATION_REMOTE_B_URL" 90001 DEST-BEFORE)"

printf 'BEFORE\nsource parallel_abort=%s\ndestination parallel_abort=%s\n' "$source_options_before" "$destination_options_before"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_before" "$destination_read_before"
printf 'source two-server rollback probe=%s\ndestination two-server rollback probe=%s\n' "$source_abort_before" "$destination_abort_before"

if [[ "$source_options_before" != 'retail_pa_a=true,retail_pa_b=true' || "$destination_options_before" != 'retail_pa_a=false,retail_pa_b=false' || "$source_read_before" != '1|7' || "$destination_read_before" != '1|7' || "$source_abort_before" != '1|1|0|0' || "$destination_abort_before" != '1|1|0|0' ]]; then
  echo 'Fixture did not establish isolated parallel_abort drift with a successful real two-foreign-server rollback path.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_PARALLEL_ABORT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(parallel_abort|parallel abort|option|incompatib|drift|mismatch)|(parallel_abort|parallel abort|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_PARALLEL_ABORT_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_PARALLEL_ABORT_DRIFT_FAIL_CLOSED=false'
  exit 2
fi

source_options_after="$(server_parallel_options "$SOURCE_ADMIN_URL")"
destination_options_after="$(server_parallel_options "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=2;')"
source_read_after="$(app_product_read "$SOURCE_APP_URL")"
destination_read_after="$(app_product_read "$DESTINATION_APP_URL")"
source_abort_after="$(rollback_probe "$SOURCE_APP_URL" "$SOURCE_REMOTE_A_URL" "$SOURCE_REMOTE_B_URL" 90002 SOURCE-AFTER)"
destination_abort_after="$(rollback_probe "$DESTINATION_APP_URL" "$DESTINATION_REMOTE_A_URL" "$DESTINATION_REMOTE_B_URL" 90002 DEST-AFTER)"

printf 'AFTER\nsource parallel_abort=%s\ndestination parallel_abort=%s\n' "$source_options_after" "$destination_options_after"
printf 'appended source row=%s\nsource app read=%s\ndestination app read=%s\n' "$destination_row_2" "$source_read_after" "$destination_read_after"
printf 'source two-server rollback probe=%s\ndestination two-server rollback probe=%s\n' "$source_abort_after" "$destination_abort_after"
printf 'NEON_FOREIGN_SERVER_PARALLEL_ABORT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$source_options_after" == 'retail_pa_a=true,retail_pa_b=true' && "$destination_options_after" == 'retail_pa_a=true,retail_pa_b=true' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' && "$source_abort_after" == '1|1|0|0' && "$destination_abort_after" == '1|1|0|0' ]]; then
  echo 'NEON_FOREIGN_SERVER_PARALLEL_ABORT_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$source_options_after" == 'retail_pa_a=true,retail_pa_b=true' && "$destination_options_after" == 'retail_pa_a=false,retail_pa_b=false' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' && "$source_abort_after" == '1|1|0|0' && "$destination_abort_after" == '1|1|0|0' ]]; then
  echo 'NEON_FOREIGN_SERVER_PARALLEL_ABORT_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_PARALLEL_ABORT_POLICY_DIVERGENCE=true'
  echo 'Destination retained parallel_abort=false; production synchronization succeeded while the same real two-foreign-server rollback path remained functional under a different remote-abort scheduling policy.' >&2
  exit 1
fi

echo 'Post-sync parallel_abort scenario produced an unexpected runtime state.' >&2
exit 2

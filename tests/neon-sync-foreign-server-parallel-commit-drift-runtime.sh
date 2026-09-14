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
create or replace function public.delay_remote_commit() returns trigger
language plpgsql as $$
begin
  perform pg_sleep(1.5);
  return new;
end
$$;
create constraint trigger remote_commit_delay
  after insert on public.remote_items
  deferrable initially deferred
  for each row execute function public.delay_remote_commit();
grant usage on schema public to cycle_app;
grant select, insert, delete on public.remote_items to cycle_app;
SQL
}

for url in "$SOURCE_REMOTE_A_URL" "$SOURCE_REMOTE_B_URL" "$DESTINATION_REMOTE_A_URL" "$DESTINATION_REMOTE_B_URL"; do
  setup_remote "$url"
done

setup_main() {
  local admin_url="$1" remote_a_db="$2" remote_b_db="$3" parallel_commit="$4"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v remote_a_db="$remote_a_db" -v remote_b_db="$remote_b_db" -v pc="$parallel_commit" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_pc_a foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, parallel_commit %L)', :'remote_a_db', :'pc') \gexec
select format('create server retail_pc_b foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L, parallel_commit %L)', :'remote_b_db', :'pc') \gexec
create user mapping for cycle_app server retail_pc_a options (user 'cycle_app', password_required 'false');
create user mapping for cycle_app server retail_pc_b options (user 'cycle_app', password_required 'false');
create user mapping for postgres server retail_pc_a options (user 'postgres', password_required 'false');
create user mapping for postgres server retail_pc_b options (user 'postgres', password_required 'false');
create foreign table public.pc_a(id bigint, note text) server retail_pc_a options (schema_name 'public', table_name 'remote_items');
create foreign table public.pc_b(id bigint, note text) server retail_pc_b options (schema_name 'public', table_name 'remote_items');
grant select, insert on public.pc_a, public.pc_b to cycle_app;
SQL
}

setup_main "$SOURCE_ADMIN_URL" cycle_d_source_a cycle_d_source_b true
setup_main "$DESTINATION_ADMIN_URL" cycle_d_destination_a cycle_d_destination_b false
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

server_parallel_options() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select string_agg(s.srvname || '=' || o.option_value, ',' order by s.srvname) from pg_foreign_server s cross join lateral pg_options_to_table(s.srvoptions) o where s.srvname in ('retail_pc_a','retail_pc_b') and o.option_name='parallel_commit';"
}

app_product_read() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c 'select count(*),coalesce(sum(quantity),0) from public.products;'
}

commit_probe() {
  local app_url="$1" probe_id="$2" label="$3"
  local start_ms end_ms
  start_ms="$(date +%s%3N)"
  psql "$app_url" -v ON_ERROR_STOP=1 -q >/dev/null <<SQL
begin;
insert into public.pc_a values (${probe_id}, '${label}-a');
insert into public.pc_b values (${probe_id}, '${label}-b');
commit;
SQL
  end_ms="$(date +%s%3N)"
  printf '%s' "$((end_ms - start_ms))"
}

cleanup_probe() {
  local url_a="$1" url_b="$2" probe_id="$3"
  psql "$url_a" -v ON_ERROR_STOP=1 -q -c "delete from public.remote_items where id=${probe_id};"
  psql "$url_b" -v ON_ERROR_STOP=1 -q -c "delete from public.remote_items where id=${probe_id};"
}

verify_timing_boundary() {
  local source_ms="$1" destination_ms="$2"
  [[ "$source_ms" -le 2400 && "$destination_ms" -ge 2600 && $((destination_ms - source_ms)) -ge 900 ]]
}

source_options_before="$(server_parallel_options "$SOURCE_ADMIN_URL")"
destination_options_before="$(server_parallel_options "$DESTINATION_ADMIN_URL")"
source_read_before="$(app_product_read "$SOURCE_APP_URL")"
destination_read_before="$(app_product_read "$DESTINATION_APP_URL")"
source_commit_before="$(commit_probe "$SOURCE_APP_URL" 90001 SOURCE-BEFORE)"
cleanup_probe "$SOURCE_REMOTE_A_URL" "$SOURCE_REMOTE_B_URL" 90001
destination_commit_before="$(commit_probe "$DESTINATION_APP_URL" 90001 DEST-BEFORE)"
cleanup_probe "$DESTINATION_REMOTE_A_URL" "$DESTINATION_REMOTE_B_URL" 90001

printf 'BEFORE\nsource parallel_commit=%s\ndestination parallel_commit=%s\n' "$source_options_before" "$destination_options_before"
printf 'source app read=%s\ndestination app read=%s\n' "$source_read_before" "$destination_read_before"
printf 'source two-server commit ms=%s\ndestination two-server commit ms=%s\n' "$source_commit_before" "$destination_commit_before"

if [[ "$source_options_before" != 'retail_pc_a=true,retail_pc_b=true' || "$destination_options_before" != 'retail_pc_a=false,retail_pc_b=false' || "$source_read_before" != '1|7' || "$destination_read_before" != '1|7' ]] || ! verify_timing_boundary "$source_commit_before" "$destination_commit_before"; then
  echo 'Fixture did not establish isolated parallel_commit drift with observable two-server commit-latency divergence.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_SERVER_PARALLEL_COMMIT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'foreign server.*(parallel_commit|parallel commit|option|incompatib|drift|mismatch)|(parallel_commit|parallel commit|option|drift|mismatch).*foreign server' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_SERVER_PARALLEL_COMMIT_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_SERVER_PARALLEL_COMMIT_DRIFT_FAIL_CLOSED=false'
  exit 2
fi

source_options_after="$(server_parallel_options "$SOURCE_ADMIN_URL")"
destination_options_after="$(server_parallel_options "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=2;')"
source_read_after="$(app_product_read "$SOURCE_APP_URL")"
destination_read_after="$(app_product_read "$DESTINATION_APP_URL")"
source_commit_after="$(commit_probe "$SOURCE_APP_URL" 90002 SOURCE-AFTER)"
cleanup_probe "$SOURCE_REMOTE_A_URL" "$SOURCE_REMOTE_B_URL" 90002
destination_commit_after="$(commit_probe "$DESTINATION_APP_URL" 90002 DEST-AFTER)"
cleanup_probe "$DESTINATION_REMOTE_A_URL" "$DESTINATION_REMOTE_B_URL" 90002

printf 'AFTER\nsource parallel_commit=%s\ndestination parallel_commit=%s\n' "$source_options_after" "$destination_options_after"
printf 'appended source row=%s\nsource app read=%s\ndestination app read=%s\n' "$destination_row_2" "$source_read_after" "$destination_read_after"
printf 'source two-server commit ms=%s\ndestination two-server commit ms=%s\n' "$source_commit_after" "$destination_commit_after"
printf 'NEON_FOREIGN_SERVER_PARALLEL_COMMIT_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$source_options_after" == 'retail_pc_a=true,retail_pc_b=true' && "$destination_options_after" == 'retail_pc_a=true,retail_pc_b=true' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' ]]; then
  echo 'NEON_FOREIGN_SERVER_PARALLEL_COMMIT_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$source_options_after" == 'retail_pc_a=true,retail_pc_b=true' && "$destination_options_after" == 'retail_pc_a=false,retail_pc_b=false' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_read_after" == '2|18' && "$destination_read_after" == '2|18' ]] && verify_timing_boundary "$source_commit_after" "$destination_commit_after"; then
  echo 'NEON_FOREIGN_SERVER_PARALLEL_COMMIT_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_SERVER_PARALLEL_COMMIT_LATENCY_DIVERGENCE=true'
  echo 'Destination retained parallel_commit=false; production synchronization succeeded while the same two-foreign-server application transaction committed serially instead of in parallel.' >&2
  exit 1
fi

echo 'Post-sync parallel_commit scenario produced an unexpected runtime state.' >&2
exit 2

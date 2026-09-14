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
  local admin_url="$1" table_remote_estimate="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v table_remote_estimate="$table_remote_estimate" <<'SQL'
create extension postgres_fdw;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create index products_quantity_idx on public.products(quantity);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options (host ''127.0.0.1'', port ''5432'', dbname %L)', current_database()) \gexec
create user mapping for cycle_app server retail_loopback options (user 'cycle_app', password_required 'false');
select format('create foreign table public.products_remote(id bigint, sku text, quantity integer) server retail_loopback options (schema_name ''public'', table_name ''products'', use_remote_estimate %L)', :'table_remote_estimate') \gexec
grant select on public.products_remote to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" false
setup_db "$DESTINATION_ADMIN_URL" true

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
insert into public.products
select g, 'SKU-' || g, case when g <= 10 then 999 else g % 17 end from generate_series(1,20000) g;
analyze public.products;
SQL
done

table_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select option_value from pg_options_to_table((select ftoptions from pg_foreign_table ft join pg_class c on c.oid=ft.ftrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='products_remote')) where option_name='use_remote_estimate';"
}
server_option() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select coalesce((select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='use_remote_estimate'),'<absent>');"
}
application_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select count(*),coalesce(sum(quantity),0) from public.products_remote where quantity=999;"
}
plan_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "explain (costs on, verbose off) select id,sku,quantity from public.products_remote where quantity=999 order by id limit 5;"
}

source_table_before="$(table_option "$SOURCE_ADMIN_URL")"
destination_table_before="$(table_option "$DESTINATION_ADMIN_URL")"
source_server_before="$(server_option "$SOURCE_ADMIN_URL")"
destination_server_before="$(server_option "$DESTINATION_ADMIN_URL")"
source_app_before="$(application_probe "$SOURCE_APP_URL")"
destination_app_before="$(application_probe "$DESTINATION_APP_URL")"
source_plan_before="$(plan_probe "$SOURCE_APP_URL")"
destination_plan_before="$(plan_probe "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource table use_remote_estimate=%s\ndestination table use_remote_estimate=%s\n' "$source_table_before" "$destination_table_before"
printf 'source server use_remote_estimate=%s\ndestination server use_remote_estimate=%s\n' "$source_server_before" "$destination_server_before"
printf 'source application probe=%s\ndestination application probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'SOURCE PLAN BEFORE\n%s\nDESTINATION PLAN BEFORE\n%s\n' "$source_plan_before" "$destination_plan_before"

if [[ "$source_table_before" != false || "$destination_table_before" != true || "$source_server_before" != '<absent>' || "$destination_server_before" != '<absent>' || "$source_app_before" != "$destination_app_before" || "$source_plan_before" == "$destination_plan_before" ]]; then
  echo 'Fixture did not establish isolated foreign-table use_remote_estimate planning drift with equal application results.' >&2
  exit 2
fi
if ! grep -q 'Foreign Scan' <<<"$source_plan_before" || ! grep -q 'Foreign Scan' <<<"$destination_plan_before"; then
  echo 'Fixture did not exercise a real postgres_fdw Foreign Scan.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_FOREIGN_TABLE_USE_REMOTE_ESTIMATE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'use_remote_estimate|remote estimate|foreign table.*(estimate|option|drift|mismatch)' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_TABLE_USE_REMOTE_ESTIMATE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_TABLE_USE_REMOTE_ESTIMATE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_table_after="$(table_option "$DESTINATION_ADMIN_URL")"
destination_server_after="$(server_option "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=20001;")"
source_app_after="$(application_probe "$SOURCE_APP_URL")"
destination_app_after="$(application_probe "$DESTINATION_APP_URL")"
source_plan_after="$(plan_probe "$SOURCE_APP_URL")"
destination_plan_after="$(plan_probe "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination table use_remote_estimate=%s\ndestination server use_remote_estimate=%s\nappended source row=%s\n' "$destination_table_after" "$destination_server_after" "$destination_row"
printf 'source application probe=%s\ndestination application probe=%s\n' "$source_app_after" "$destination_app_after"
printf 'SOURCE PLAN AFTER\n%s\nDESTINATION PLAN AFTER\n%s\n' "$source_plan_after" "$destination_plan_after"
printf 'NEON_FOREIGN_TABLE_USE_REMOTE_ESTIMATE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_table_after" == false && "$destination_server_after" == '<absent>' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$source_app_after" == "$destination_app_after" && "$source_plan_after" == "$destination_plan_after" ]]; then
  echo 'NEON_FOREIGN_TABLE_USE_REMOTE_ESTIMATE_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_table_after" == true && "$destination_server_after" == '<absent>' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$source_app_after" == "$destination_app_after" && "$source_plan_before" == "$source_plan_after" && "$destination_plan_before" == "$destination_plan_after" && "$source_plan_after" != "$destination_plan_after" ]]; then
  echo 'NEON_FOREIGN_TABLE_USE_REMOTE_ESTIMATE_DRIFT_DETECTED=false'
  echo 'NEON_FOREIGN_TABLE_USE_REMOTE_ESTIMATE_PLAN_DIVERGENCE=true'
  echo 'Destination retained a different foreign-table postgres_fdw remote-estimation override; production synchronization succeeded while real Foreign Scan planner costs remained different from source.' >&2
  exit 1
fi

echo 'Post-sync foreign-table use_remote_estimate scenario produced an unexpected runtime state.' >&2
exit 2

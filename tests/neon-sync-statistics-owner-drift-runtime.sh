#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_table_owner nologin;"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "grant cycle_table_owner to cycle_owner, cycle_other;"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

setup_source() {
  psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products(
  id bigint primary key,
  sku text not null,
  quantity integer not null,
  category_id integer not null,
  warehouse_id integer not null
);
alter table public.products owner to cycle_table_owner;
grant usage, create on schema public to cycle_owner, cycle_other;
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
insert into public.products
select g, 'SKU-' || g, g % 17, ((g - 1) % 100) + 1, ((g - 1) % 100) + 1
from generate_series(1,10000) g;
insert into public.products values (20001,'SOURCE-SKU-20001',11,42,42);
set role cycle_owner;
create statistics public.retail_product_corr (dependencies)
on category_id, warehouse_id from public.products;
reset role;
analyze public.products;
SQL
}

setup_destination() {
  psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products(
  id bigint primary key,
  sku text not null,
  quantity integer not null,
  category_id integer not null,
  warehouse_id integer not null
);
alter table public.products owner to cycle_table_owner;
grant usage, create on schema public to cycle_owner, cycle_other;
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
insert into public.products
select g, 'SKU-' || g, g % 17, ((g - 1) % 100) + 1, ((g - 1) % 100) + 1
from generate_series(1,10000) g;
set role cycle_other;
create statistics public.retail_product_corr (dependencies)
on category_id, warehouse_id from public.products;
reset role;
analyze public.products;
SQL
}

setup_source
setup_destination

statistics_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(s.stxowner) from pg_statistic_ext s join pg_namespace n on n.oid=s.stxnamespace where n.nspname='public' and s.stxname='retail_product_corr';"
}
app_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products where category_id=42 and warehouse_id=42 and id < 20000;"
}
plan_rows() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "explain (format json) select * from public.products where category_id=42 and warehouse_id=42 and id < 20000;" | python3 -c 'import json,sys; p=json.load(sys.stdin)[0]["Plan"]; print(p.get("Plan Rows"))'
}
drop_statistics_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c 'drop statistics public.retail_product_corr;'
}
restore_destination_statistics() {
  psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
set role cycle_other;
create statistics public.retail_product_corr (dependencies)
on category_id, warehouse_id from public.products;
reset role;
analyze public.products;
SQL
}

source_owner_before="$(statistics_owner "$SOURCE_ADMIN_URL")"
destination_owner_before="$(statistics_owner "$DESTINATION_ADMIN_URL")"
source_count_before="$(app_count "$SOURCE_APP_URL")"
destination_count_before="$(app_count "$DESTINATION_APP_URL")"
source_rows_before="$(plan_rows "$SOURCE_APP_URL")"
destination_rows_before="$(plan_rows "$DESTINATION_APP_URL")"

set +e
source_drop_output="$(drop_statistics_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_exit=$?
destination_drop_output="$(drop_statistics_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_exit=$?
set -e
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'analyze public.products;'
destination_rows_after_drop="$(plan_rows "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource statistics owner=%s\ndestination statistics owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source app count=%s\ndestination app count=%s\nsource plan rows=%s\ndestination plan rows=%s\n' "$source_count_before" "$destination_count_before" "$source_rows_before" "$destination_rows_before"
printf 'source cycle_other drop exit=%s\nsource cycle_other output=%s\n' "$source_drop_exit" "$source_drop_output"
printf 'destination cycle_other drop exit=%s\ndestination cycle_other output=%s\ndestination plan rows after owner drop=%s\n' "$destination_drop_exit" "$destination_drop_output" "$destination_rows_after_drop"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_count_before" != 100 || "$destination_count_before" != 100 || "$source_drop_exit" -eq 0 || "$destination_drop_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated statistics ownership drift.' >&2
  exit 2
fi
if [[ "$source_rows_before" != "$destination_rows_before" || "$destination_rows_after_drop" == "$destination_rows_before" ]]; then
  echo 'Fixture did not establish the expected planner-estimate effect from dropping extended statistics.' >&2
  exit 2
fi

restore_destination_statistics
if [[ "$(statistics_owner "$DESTINATION_ADMIN_URL")" != cycle_other || "$(plan_rows "$DESTINATION_APP_URL")" != "$source_rows_before" ]]; then
  echo 'Fixture restoration failed before production synchronization.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_STATISTICS_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'statistics.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*statistics' <<<"$runtime_output"; then
    echo 'NEON_STATISTICS_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_STATISTICS_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(statistics_owner "$DESTINATION_ADMIN_URL")"
destination_row_20001="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity,category_id,warehouse_id from public.products where id=20001;")"
source_rows_after_sync="$(plan_rows "$SOURCE_APP_URL")"
destination_rows_before_final_drop="$(plan_rows "$DESTINATION_APP_URL")"

set +e
source_drop_after_output="$(drop_statistics_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_after_exit=$?
destination_drop_after_output="$(drop_statistics_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_after_exit=$?
set -e
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'analyze public.products;'
destination_rows_after_final_drop="$(plan_rows "$DESTINATION_APP_URL")"
destination_count_after_final_drop="$(app_count "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination statistics owner=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_row_20001"
printf 'source plan rows after sync=%s\ndestination plan rows before final drop=%s\n' "$source_rows_after_sync" "$destination_rows_before_final_drop"
printf 'source cycle_other final drop exit=%s\nsource cycle_other final output=%s\n' "$source_drop_after_exit" "$source_drop_after_output"
printf 'destination cycle_other final drop exit=%s\ndestination cycle_other final output=%s\n' "$destination_drop_after_exit" "$destination_drop_after_output"
printf 'destination plan rows after final drop=%s\ndestination app count after final drop=%s\nNEON_STATISTICS_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_rows_after_final_drop" "$destination_count_after_final_drop" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_row_20001" == '20001|SOURCE-SKU-20001|11|42|42' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -ne 0 && "$source_rows_after_sync" == "$destination_rows_before_final_drop" ]]; then
  echo 'NEON_STATISTICS_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_row_20001" == '20001|SOURCE-SKU-20001|11|42|42' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -eq 0 && "$source_rows_after_sync" == "$destination_rows_before_final_drop" && "$destination_rows_after_final_drop" != "$destination_rows_before_final_drop" && "$destination_count_after_final_drop" == 100 ]]; then
  echo 'NEON_STATISTICS_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained extended-statistics owner authority that source assigns to a different role; owner-only DROP changed planner cardinality estimates while application results remained correct.' >&2
  exit 1
fi

echo 'Post-sync statistics ownership scenario produced an unexpected runtime state.' >&2
exit 2

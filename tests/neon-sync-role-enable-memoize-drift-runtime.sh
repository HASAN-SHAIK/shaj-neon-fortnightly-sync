#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_memoize = on;
alter role cycle_app set enable_hashjoin = off;
alter role cycle_app set enable_mergejoin = off;
alter role cycle_app set enable_nestloop = on;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_memoize = off;
alter role cycle_app set enable_hashjoin = off;
alter role cycle_app set enable_mergejoin = off;
alter role cycle_app set enable_nestloop = on;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.memo_products (id integer primary key, payload text not null);
create table public.memo_orders (id integer primary key, product_id integer not null, payload text not null);
create index memo_orders_product_id_idx on public.memo_orders(product_id);
grant usage on schema public to cycle_app;
grant select on public.products, public.memo_products, public.memo_orders to cycle_app;
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.memo_products select g, 'P-' || g from generate_series(1,100) g;
insert into public.memo_orders select g, ((g - 1) % 100) + 1, 'O-' || g from generate_series(1,20000) g;
analyze public.products; analyze public.memo_products; analyze public.memo_orders;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_memoize=%';"
}
probe_plan() {
  local url="$1" memoize plan result row
  memoize="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_memoize;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'explain (costs off) select count(*) from public.memo_orders o join public.memo_products p on p.id=o.product_id where o.id <= 20000;' | tr '\n' ';')"
  result="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'select count(*) from public.memo_orders o join public.memo_products p on p.id=o.product_id where o.id <= 20000;')"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  printf '%s|%s|count=%s|%s' "$memoize" "$plan" "$result" "$row"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"; destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_plan "$SOURCE_APP_URL")"; destination_probe="$(probe_plan "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app memoize probe=%s\ndestination app memoize probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"
[[ "${source_setting,,}" == 'enable_memoize=on' && "${destination_setting,,}" == 'enable_memoize=off' ]] || { echo 'Fixture did not establish enable_memoize drift.' >&2; exit 2; }
[[ "$source_probe" == on\|*"Memoize"*"Nested Loop"*"|count=20000|15000|SOURCE-SKU-15000|0" ]] || { echo "Source did not use expected Memoize nested-loop plan: $source_probe" >&2; exit 2; }
[[ "$destination_probe" == off\|*"Nested Loop"*"|count=20000|15000|SOURCE-SKU-15000|0" && "$destination_probe" != *"Memoize"* ]] || { echo "Destination did not use expected non-Memoize nested-loop plan: $destination_probe" >&2; exit 2; }

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_MEMOIZE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enable_memoize|pg_db_role_setting|role setting' <<<"$runtime_output"; then echo 'NEON_ROLE_ENABLE_MEMOIZE_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_ROLE_ENABLE_MEMOIZE_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
source_probe_after="$(probe_plan "$SOURCE_APP_URL")"; destination_probe_after="$(probe_plan "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app memoize probe=%s\ndestination app memoize probe=%s\nNEON_ROLE_ENABLE_MEMOIZE_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row" "$source_probe_after" "$destination_probe_after" "$sync_exit"
if [[ "$source_probe_after" != on\|*"Memoize"*"Nested Loop"*"|count=20000|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" != off\|*"Nested Loop"*"|count=20000|15000|SOURCE-SKU-15000|0" || "$destination_probe_after" == *"Memoize"* ]]; then
  echo 'Post-sync fixture/data no longer isolates the intended enable_memoize planner boundary.' >&2
  exit 2
fi
if [[ "${destination_setting_after,,}" == 'enable_memoize=on' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$destination_probe_after" == on\|*"Memoize"* ]]; then echo 'NEON_ROLE_ENABLE_MEMOIZE_DRIFT_DETECTED=true'; exit 0; fi
echo 'NEON_ROLE_ENABLE_MEMOIZE_DRIFT_DETECTED=false'
exit 1

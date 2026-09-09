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
alter role cycle_app set enable_indexscan = on;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_indexscan = off;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
create index products_sku_idx on public.products(sku);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || g, g % 100
from generate_series(1, 20000) as g;
analyze public.products;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) as cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_indexscan=%';"
}

probe_plan() {
  local url="$1"
  local setting plan row
  setting="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "show enable_indexscan;")"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) select id,sku,quantity from public.products where sku='SOURCE-SKU-15000';" | tr '\n' ';')"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where sku='SOURCE-SKU-15000';")"
  printf '%s|%s|%s' "$setting" "$plan" "$row"
}

source_setting="$(role_setting "$SOURCE_ADMIN_URL")"
destination_setting="$(role_setting "$DESTINATION_ADMIN_URL")"
source_probe="$(probe_plan "$SOURCE_APP_URL")"
destination_probe="$(probe_plan "$DESTINATION_APP_URL")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app plan probe=%s\ndestination app plan probe=%s\n' "$source_setting" "$destination_setting" "$source_probe" "$destination_probe"

if [[ "${source_setting,,}" != 'enable_indexscan=on' || "${destination_setting,,}" != 'enable_indexscan=off' ]]; then
  echo 'Fixture did not establish enable_indexscan drift.' >&2; exit 2
fi
if [[ "$source_probe" != on\|*"Index Scan using products_sku_idx on products"*"|15000|SOURCE-SKU-15000|0" ]]; then
  echo "Source enable_indexscan=on probe did not use the expected index scan while preserving application data: $source_probe" >&2; exit 2
fi
if [[ "$destination_probe" != off\|* || "$destination_probe" != *"|15000|SOURCE-SKU-15000|0" ]]; then
  echo "Destination enable_indexscan=off probe did not preserve application data: $destination_probe" >&2; exit 2
fi
if [[ "$destination_probe" == *"Index Scan using products_sku_idx on products"* || "$destination_probe" != *"Bitmap"* ]]; then
  echo "Destination enable_indexscan=off probe did not choose the expected non-indexscan bitmap plan: $destination_probe" >&2; exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_INDEXSCAN_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enable_indexscan|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_ENABLE_INDEXSCAN_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_ENABLE_INDEXSCAN_DRIFT_FAIL_CLOSED=false'; exit 1
fi

destination_setting_after="$(role_setting "$DESTINATION_ADMIN_URL")"
destination_row="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=20001;")"
source_probe_after="$(probe_plan "$SOURCE_APP_URL")"
destination_probe_after="$(probe_plan "$DESTINATION_APP_URL")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app plan probe=%s\ndestination app plan probe=%s\nNEON_ROLE_ENABLE_INDEXSCAN_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row" "$source_probe_after" "$destination_probe_after" "$sync_exit"

if [[ "${destination_setting_after,,}" == 'enable_indexscan=on' && "$destination_row" == '20001|SOURCE-SKU-20001|11' && "$destination_probe_after" == on\|*"Index Scan using products_sku_idx on products"* ]]; then
  echo 'NEON_ROLE_ENABLE_INDEXSCAN_DRIFT_DETECTED=true'; exit 0
fi

echo 'NEON_ROLE_ENABLE_INDEXSCAN_DRIFT_DETECTED=false'
exit 1

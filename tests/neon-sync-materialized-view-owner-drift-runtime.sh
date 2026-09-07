#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
create materialized view public.stock_rollup as select id, sku, quantity from public.products where id=1;
alter materialized view public.stock_rollup owner to cycle_owner;
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_owner, cycle_other;
grant select on public.stock_rollup to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
create materialized view public.stock_rollup as select id, sku, quantity from public.products where id=1;
alter materialized view public.stock_rollup owner to cycle_other;
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_owner, cycle_other;
grant select on public.stock_rollup to cycle_app;
SQL

owner_of_matview() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.relowner) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='stock_rollup' and c.relkind='m';"
}
refresh_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c 'refresh materialized view public.stock_rollup;'
}
app_rows() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.stock_rollup order by id;'
}

source_owner_before="$(owner_of_matview "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_matview "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_rows "$SOURCE_APP_URL")"
destination_app_before="$(app_rows "$DESTINATION_APP_URL")"
set +e
source_refresh_output="$(refresh_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_refresh_exit=$?
destination_refresh_output="$(refresh_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_refresh_exit=$?
set -e

printf 'BEFORE\nsource materialized view owner=%s\ndestination materialized view owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source cycle_app rows=%s\ndestination cycle_app rows=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other refresh exit=%s\nsource cycle_other refresh output=%s\n' "$source_refresh_exit" "$source_refresh_output"
printf 'destination cycle_other refresh exit=%s\ndestination cycle_other refresh output=%s\n' "$destination_refresh_exit" "$destination_refresh_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_app_before" != '1|SOURCE-SKU-1|7' || "$destination_app_before" != '1|SOURCE-SKU-1|7' || "$source_refresh_exit" -eq 0 || "$destination_refresh_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated materialized-view ownership drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_MATVIEW_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'materialized.*view.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*materialized.*view.*(incompatib|drift|mismatch)' <<<"$runtime_output"; then
    echo 'NEON_MATVIEW_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_MATVIEW_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_matview "$DESTINATION_ADMIN_URL")"
destination_base_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_app_before_final="$(app_rows "$DESTINATION_APP_URL")"
set +e
destination_refresh_after_output="$(refresh_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_refresh_after_exit=$?
set -e
destination_app_after_final="$(app_rows "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination materialized view owner=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_base_row_2"
printf 'destination cycle_app rows before final refresh=%s\n' "$destination_app_before_final"
printf 'destination cycle_other refresh exit=%s\ndestination cycle_other refresh output=%s\n' "$destination_refresh_after_exit" "$destination_refresh_after_output"
printf 'destination cycle_app rows after final refresh=%s\nNEON_MATVIEW_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_base_row_2" == '2|SOURCE-SKU-2|11' && "$destination_refresh_after_exit" -ne 0 ]]; then
  echo 'NEON_MATVIEW_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_MATVIEW_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained materialized-view refresh authority that source assigns to a different owner.' >&2
exit 1

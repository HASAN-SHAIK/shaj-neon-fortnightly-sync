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
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant create on database cycle_d_source to cycle_owner, cycle_other;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant create on database cycle_d_destination to cycle_owner, cycle_other;'

setup_db() {
  local admin_url="$1" owner="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v owner="$owner" <<'SQL'
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
alter table public.products owner to cycle_table_owner;
grant usage on schema public to cycle_app, cycle_owner, cycle_other;
grant select on public.products to cycle_app;
create publication retail_products_pub for table public.products with (publish='insert, update, delete');
select format('alter publication retail_products_pub owner to %I', :'owner') \gexec
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_owner
setup_db "$DESTINATION_ADMIN_URL" cycle_other
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

publication_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(pubowner) from pg_publication where pubname='retail_products_pub';"
}
publication_table_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_publication_tables where pubname='retail_products_pub' and schemaname='public' and tablename='products';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_publication_tables where pubname='retail_products_pub' and schemaname='public' and tablename='products';"
}
drop_product_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c 'alter publication retail_products_pub drop table public.products;'
}
restore_destination_publication() {
  psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'alter publication retail_products_pub add table public.products;'
}

source_owner_before="$(publication_owner "$SOURCE_ADMIN_URL")"
destination_owner_before="$(publication_owner "$DESTINATION_ADMIN_URL")"
source_pub_before="$(publication_table_count "$SOURCE_ADMIN_URL")"
destination_pub_before="$(publication_table_count "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"
set +e
source_drop_output="$(drop_product_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_exit=$?
destination_drop_output="$(drop_product_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_exit=$?
destination_app_after="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_exit=$?
set -e
printf 'BEFORE\nsource publication owner=%s\ndestination publication owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source publication product count=%s\ndestination publication product count=%s\n' "$source_pub_before" "$destination_pub_before"
printf 'source app publication probe=%s\ndestination app publication probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other drop table exit=%s\nsource cycle_other output=%s\n' "$source_drop_exit" "$source_drop_output"
printf 'destination cycle_other drop table exit=%s\ndestination cycle_other output=%s\n' "$destination_drop_exit" "$destination_drop_output"
printf 'destination app after owner mutation exit=%s\ndestination app publication probe=%s\n' "$destination_app_after_exit" "$destination_app_after"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_pub_before" != 1 || "$destination_pub_before" != 1 || "$source_app_before" != 1 || "$destination_app_before" != 1 || "$source_drop_exit" -eq 0 || "$destination_drop_exit" -ne 0 || "$destination_app_after_exit" -ne 0 || "$destination_app_after" != 0 ]]; then
  echo 'Fixture did not establish isolated publication ownership drift.' >&2
  exit 2
fi

restore_destination_publication
[[ "$(publication_owner "$DESTINATION_ADMIN_URL")" == cycle_other ]] || exit 2
[[ "$(publication_table_count "$DESTINATION_ADMIN_URL")" == 1 ]] || exit 2
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_PUBLICATION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'publication.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*publication' <<<"$runtime_output"; then
    echo 'NEON_PUBLICATION_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_PUBLICATION_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(publication_owner "$DESTINATION_ADMIN_URL")"
destination_pub_before_final="$(publication_table_count "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
source_drop_after_output="$(drop_product_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_after_exit=$?
destination_drop_after_output="$(drop_product_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_after_exit=$?
destination_app_after_final="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_final_exit=$?
set -e
printf 'AFTER\ndestination publication owner=%s\ndestination publication product count before final mutation=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_pub_before_final" "$destination_row_2"
printf 'source cycle_other final drop exit=%s\nsource cycle_other final output=%s\n' "$source_drop_after_exit" "$source_drop_after_output"
printf 'destination cycle_other final drop exit=%s\ndestination cycle_other final output=%s\n' "$destination_drop_after_exit" "$destination_drop_after_output"
printf 'destination app final publication probe exit=%s\ndestination app final publication probe=%s\nNEON_PUBLICATION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final_exit" "$destination_app_after_final" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_pub_before_final" == 1 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -ne 0 ]]; then
  echo 'NEON_PUBLICATION_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_pub_before_final" == 1 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -eq 0 && "$destination_app_after_final_exit" -eq 0 && "$destination_app_after_final" == 0 ]]; then
  echo 'NEON_PUBLICATION_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained publication-owner authority denied on source; owner removed the products table from the real publication configuration.' >&2
  exit 1
fi

echo 'Post-sync publication ownership scenario produced an unexpected runtime state.' >&2
exit 2

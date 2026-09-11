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
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create text search configuration public.retail_search (copy = pg_catalog.english);
alter text search configuration public.retail_search owner to cycle_owner;
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
insert into public.products values
  (1,'SOURCE-SKU-1',7),
  (2,'SOURCE-SKU-2',11);
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create text search configuration public.retail_search (copy = pg_catalog.english);
alter text search configuration public.retail_search owner to cycle_other;
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
insert into public.products values
  (1,'SOURCE-SKU-1',7);
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_app;
SQL

owner_of_config() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.cfgowner) from pg_ts_config c join pg_namespace n on n.oid=c.cfgnamespace where n.nspname='public' and c.cfgname='retail_search';"
}
search_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select to_tsvector('public.retail_search'::regconfig, 'running shoes') @@ plainto_tsquery('public.retail_search'::regconfig, 'run');"
}
app_row() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=1;"
}
alter_mapping_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter text search configuration public.retail_search alter mapping for asciiword with simple;"
}
restore_mapping() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter text search configuration public.retail_search alter mapping for asciiword with english_stem;"
}

source_owner_before="$(owner_of_config "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_config "$DESTINATION_ADMIN_URL")"
source_search_before="$(search_probe "$SOURCE_APP_URL")"
destination_search_before="$(search_probe "$DESTINATION_APP_URL")"
source_app_before="$(app_row "$SOURCE_APP_URL")"
destination_app_before="$(app_row "$DESTINATION_APP_URL")"

set +e
source_alter_output="$(alter_mapping_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_alter_exit=$?
destination_alter_output="$(alter_mapping_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_alter_exit=$?
set -e

destination_search_mutated="$(search_probe "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource text search config owner=%s\ndestination text search config owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source search probe=%s\ndestination search probe=%s\n' "$source_search_before" "$destination_search_before"
printf 'source app row=%s\ndestination app row=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other alter exit=%s\nsource cycle_other output=%s\n' "$source_alter_exit" "$source_alter_output"
printf 'destination cycle_other alter exit=%s\ndestination cycle_other output=%s\ndestination search after owner mutation=%s\n' "$destination_alter_exit" "$destination_alter_output" "$destination_search_mutated"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_search_before" != t || "$destination_search_before" != t || "$source_app_before" != '1|SOURCE-SKU-1|7' || "$destination_app_before" != '1|SOURCE-SKU-1|7' || "$source_alter_exit" -eq 0 || "$destination_alter_exit" -ne 0 || "$destination_search_mutated" != f ]]; then
  echo 'Fixture did not establish isolated text-search-configuration ownership drift.' >&2
  exit 2
fi

# Restore semantic parity before production synchronization while preserving ownership drift.
restore_mapping "$DESTINATION_OTHER_URL"
restored_search="$(search_probe "$DESTINATION_APP_URL")"
if [[ "$restored_search" != t ]]; then
  echo 'Fixture restoration failed before production synchronization.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_TEXT_SEARCH_CONFIG_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'text search.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*text search' <<<"$runtime_output"; then
    echo 'NEON_TEXT_SEARCH_CONFIG_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_TEXT_SEARCH_CONFIG_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_config "$DESTINATION_ADMIN_URL")"
destination_search_before_final="$(search_probe "$DESTINATION_APP_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_alter_after_output="$(alter_mapping_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_alter_after_exit=$?
set -e
destination_search_after_final="$(search_probe "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination text search config owner=%s\ndestination search before final owner probe=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_search_before_final" "$destination_row_2"
printf 'destination cycle_other alter exit=%s\ndestination cycle_other output=%s\ndestination search after final owner mutation=%s\nNEON_TEXT_SEARCH_CONFIG_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_alter_after_exit" "$destination_alter_after_output" "$destination_search_after_final" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_search_before_final" == t && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_alter_after_exit" -ne 0 && "$destination_search_after_final" == t ]]; then
  echo 'NEON_TEXT_SEARCH_CONFIG_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_TEXT_SEARCH_CONFIG_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained text-search-configuration owner authority that source assigns to a different role.' >&2
exit 1

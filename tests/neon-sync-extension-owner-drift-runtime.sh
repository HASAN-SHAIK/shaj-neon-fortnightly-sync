#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OWNER_URL='postgresql://cycle_owner:cycle@127.0.0.1:55432/cycle_d_source'
DESTINATION_OWNER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
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
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant create on database cycle_d_source to cycle_owner, cycle_other;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant create on database cycle_d_destination to cycle_owner, cycle_other;'

setup_db() {
  local admin_url="$1"
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
grant usage, create on schema public to cycle_owner, cycle_other;
grant usage on schema public to cycle_app;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
grant select on public.products to cycle_app;
SQL
}
setup_db "$SOURCE_ADMIN_URL"
setup_db "$DESTINATION_ADMIN_URL"

# hstore is a trusted PostgreSQL contrib extension. Install it through different
# real roles so the extension catalog owner differs while behavior starts equal.
psql "$SOURCE_OWNER_URL" -v ON_ERROR_STOP=1 -c 'create extension hstore with schema public;'
psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 -c 'create extension hstore with schema public;'
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

extension_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(extowner) from pg_extension where extname='hstore';"
}
extension_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_extension where extname='hstore';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select ('sku=>BASE,qty=>7'::public.hstore -> 'sku') || '|' || ('sku=>BASE,qty=>7'::public.hstore -> 'qty');"
}
drop_extension_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c 'drop extension hstore;'
}
restore_destination_extension() {
  psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c 'create extension hstore with schema public;'
}

source_owner_before="$(extension_owner "$SOURCE_ADMIN_URL")"
destination_owner_before="$(extension_owner "$DESTINATION_ADMIN_URL")"
source_extension_before="$(extension_count "$SOURCE_ADMIN_URL")"
destination_extension_before="$(extension_count "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"
set +e
source_drop_output="$(drop_extension_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_exit=$?
destination_drop_output="$(drop_extension_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_exit=$?
destination_app_after_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_exit=$?
set -e
printf 'BEFORE\nsource extension owner=%s\ndestination extension owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source hstore extension count=%s\ndestination hstore extension count=%s\n' "$source_extension_before" "$destination_extension_before"
printf 'source app hstore probe=%s\ndestination app hstore probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other drop extension exit=%s\nsource cycle_other output=%s\n' "$source_drop_exit" "$source_drop_output"
printf 'destination cycle_other drop extension exit=%s\ndestination cycle_other output=%s\n' "$destination_drop_exit" "$destination_drop_output"
printf 'destination app after owner mutation exit=%s\ndestination app output=%s\n' "$destination_app_after_exit" "$destination_app_after_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_extension_before" != 1 || "$destination_extension_before" != 1 || "$source_app_before" != 'BASE|7' || "$destination_app_before" != 'BASE|7' || "$source_drop_exit" -eq 0 || "$destination_drop_exit" -ne 0 || "$destination_app_after_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated extension ownership/application drift.' >&2
  exit 2
fi

restore_destination_extension
[[ "$(extension_owner "$DESTINATION_ADMIN_URL")" == cycle_other ]] || exit 2
[[ "$(extension_count "$DESTINATION_ADMIN_URL")" == 1 ]] || exit 2
[[ "$(app_probe "$DESTINATION_APP_URL")" == 'BASE|7' ]] || exit 2
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_EXTENSION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'extension.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*extension' <<<"$runtime_output"; then
    echo 'NEON_EXTENSION_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_EXTENSION_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(extension_owner "$DESTINATION_ADMIN_URL")"
destination_extension_after="$(extension_count "$DESTINATION_ADMIN_URL")"
destination_app_before_final="$(app_probe "$DESTINATION_APP_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
source_drop_after_output="$(drop_extension_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_after_exit=$?
destination_drop_after_output="$(drop_extension_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_after_exit=$?
destination_app_after_final_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_final_exit=$?
set -e
printf 'AFTER\ndestination extension owner=%s\ndestination hstore extension count before final mutation=%s\n' "$destination_owner_after" "$destination_extension_after"
printf 'destination app hstore probe before final mutation=%s\nappended source row=%s\n' "$destination_app_before_final" "$destination_row_2"
printf 'source cycle_other final drop extension exit=%s\nsource cycle_other final output=%s\n' "$source_drop_after_exit" "$source_drop_after_output"
printf 'destination cycle_other final drop extension exit=%s\ndestination cycle_other final output=%s\n' "$destination_drop_after_exit" "$destination_drop_after_output"
printf 'destination app final probe exit=%s\ndestination app final output=%s\nNEON_EXTENSION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final_exit" "$destination_app_after_final_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_extension_after" == 1 && "$destination_app_before_final" == 'BASE|7' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -ne 0 ]]; then
  echo 'NEON_EXTENSION_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_extension_after" == 1 && "$destination_app_before_final" == 'BASE|7' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -eq 0 && "$destination_app_after_final_exit" -ne 0 ]]; then
  echo 'NEON_EXTENSION_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained extension-owner authority denied on source; owner removed the application-used hstore extension after production synchronization reported success.' >&2
  exit 1
fi

echo 'Post-sync extension ownership scenario produced an unexpected runtime state.' >&2
exit 2

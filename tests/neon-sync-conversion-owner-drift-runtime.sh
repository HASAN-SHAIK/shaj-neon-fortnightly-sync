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

psql "$SOURCE_OWNER_URL" -v ON_ERROR_STOP=1 -c "create conversion public.retail_utf8_to_latin1 for 'UTF8' to 'LATIN1' from pg_catalog.utf8_to_iso8859_1;"
psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 -c "create conversion public.retail_utf8_to_latin1 for 'UTF8' to 'LATIN1' from pg_catalog.utf8_to_iso8859_1;"
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

conversion_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(conowner) from pg_conversion where connamespace='public'::regnamespace and conname='retail_utf8_to_latin1';"
}
conversion_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_conversion where connamespace='public'::regnamespace and conname='retail_utf8_to_latin1';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_conversion where connamespace='public'::regnamespace and conname='retail_utf8_to_latin1' and pg_encoding_to_char(conforencoding)='UTF8' and pg_encoding_to_char(contoencoding)='LATIN1';"
}
rename_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c 'alter conversion public.retail_utf8_to_latin1 rename to retail_utf8_to_latin1_hijacked;'
}
restore_destination() {
  psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c 'alter conversion public.retail_utf8_to_latin1_hijacked rename to retail_utf8_to_latin1;'
}

source_owner_before="$(conversion_owner "$SOURCE_ADMIN_URL")"
destination_owner_before="$(conversion_owner "$DESTINATION_ADMIN_URL")"
source_count_before="$(conversion_count "$SOURCE_ADMIN_URL")"
destination_count_before="$(conversion_count "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"
set +e
source_rename_output="$(rename_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_rename_exit=$?
destination_rename_output="$(rename_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_exit=$?
destination_app_after_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_exit=$?
set -e
printf 'BEFORE\nsource conversion owner=%s\ndestination conversion owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source conversion count=%s\ndestination conversion count=%s\n' "$source_count_before" "$destination_count_before"
printf 'source app conversion catalog probe=%s\ndestination app conversion catalog probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other rename exit=%s\nsource cycle_other output=%s\n' "$source_rename_exit" "$source_rename_output"
printf 'destination cycle_other rename exit=%s\ndestination cycle_other output=%s\n' "$destination_rename_exit" "$destination_rename_output"
printf 'destination app catalog probe after owner mutation exit=%s\noutput=%s\n' "$destination_app_after_exit" "$destination_app_after_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_count_before" != 1 || "$destination_count_before" != 1 || "$source_app_before" != 1 || "$destination_app_before" != 1 || "$source_rename_exit" -eq 0 || "$destination_rename_exit" -ne 0 || "$destination_app_after_exit" -ne 0 || "$destination_app_after_output" != 0 ]]; then
  echo 'Fixture did not establish isolated conversion ownership/catalog drift.' >&2
  exit 2
fi

restore_destination
[[ "$(conversion_owner "$DESTINATION_ADMIN_URL")" == cycle_other ]] || exit 2
[[ "$(conversion_count "$DESTINATION_ADMIN_URL")" == 1 ]] || exit 2
[[ "$(app_probe "$DESTINATION_APP_URL")" == 1 ]] || exit 2
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_CONVERSION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'conversion.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*conversion' <<<"$runtime_output"; then
    echo 'NEON_CONVERSION_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_CONVERSION_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(conversion_owner "$DESTINATION_ADMIN_URL")"
destination_count_after="$(conversion_count "$DESTINATION_ADMIN_URL")"
destination_app_before_final="$(app_probe "$DESTINATION_APP_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
source_rename_after_output="$(rename_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_rename_after_exit=$?
destination_rename_after_output="$(rename_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_after_exit=$?
destination_app_after_final_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_final_exit=$?
set -e
printf 'AFTER\ndestination conversion owner=%s\ndestination conversion count before final mutation=%s\n' "$destination_owner_after" "$destination_count_after"
printf 'destination app catalog probe before final mutation=%s\nappended source row=%s\n' "$destination_app_before_final" "$destination_row_2"
printf 'source cycle_other final rename exit=%s\nsource cycle_other final output=%s\n' "$source_rename_after_exit" "$source_rename_after_output"
printf 'destination cycle_other final rename exit=%s\ndestination cycle_other final output=%s\n' "$destination_rename_after_exit" "$destination_rename_after_output"
printf 'destination app final catalog probe exit=%s\noutput=%s\nNEON_CONVERSION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final_exit" "$destination_app_after_final_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_count_after" == 1 && "$destination_app_before_final" == 1 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_rename_after_exit" -ne 0 && "$destination_rename_after_exit" -ne 0 ]]; then
  echo 'NEON_CONVERSION_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_count_after" == 1 && "$destination_app_before_final" == 1 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_rename_after_exit" -ne 0 && "$destination_rename_after_exit" -eq 0 && "$destination_app_after_final_exit" -eq 0 && "$destination_app_after_final_output" == 0 ]]; then
  echo 'NEON_CONVERSION_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained conversion-owner authority denied on source; owner renamed the source-named conversion after production synchronization reported success.' >&2
  exit 1
fi

echo 'Post-sync conversion ownership scenario produced an unexpected runtime state.' >&2
exit 2

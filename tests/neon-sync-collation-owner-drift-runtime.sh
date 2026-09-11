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
create collation public.retail_sort (provider = libc, locale = 'C');
alter collation public.retail_sort owner to cycle_owner;
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
insert into public.products values
  (1,'zebra',7),
  (2,'alpha',11);
grant usage, create on schema public to cycle_other;
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create collation public.retail_sort (provider = libc, locale = 'C');
alter collation public.retail_sort owner to cycle_other;
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
insert into public.products values
  (1,'zebra',7);
grant usage, create on schema public to cycle_other;
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL

owner_of_collation() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.collowner) from pg_collation c join pg_namespace n on n.oid=c.collnamespace where n.nspname='public' and c.collname='retail_sort';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products order by sku collate public.retail_sort, id;"
}
rename_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter collation public.retail_sort rename to retail_sort_hijacked;"
}
restore_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter collation public.retail_sort_hijacked rename to retail_sort;"
}

source_owner_before="$(owner_of_collation "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_collation "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"

set +e
source_rename_output="$(rename_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_rename_exit=$?
destination_rename_output="$(rename_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_exit=$?
destination_app_mutated="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_mutated_exit=$?
set -e

printf 'BEFORE\nsource collation owner=%s\ndestination collation owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source app probe=%s\ndestination app probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other rename exit=%s\nsource cycle_other output=%s\n' "$source_rename_exit" "$source_rename_output"
printf 'destination cycle_other rename exit=%s\ndestination cycle_other output=%s\n' "$destination_rename_exit" "$destination_rename_output"
printf 'destination app probe after owner mutation exit=%s\ndestination app output=%s\n' "$destination_app_mutated_exit" "$destination_app_mutated"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_app_before" != $'2|alpha|11\n1|zebra|7' || "$destination_app_before" != '1|zebra|7' || "$source_rename_exit" -eq 0 || "$destination_rename_exit" -ne 0 || "$destination_app_mutated_exit" -eq 0 || "$destination_app_mutated" != *'collation "public.retail_sort" for encoding "UTF8" does not exist'* ]]; then
  echo 'Fixture did not establish isolated collation ownership drift.' >&2
  exit 2
fi

# Restore the destination object name before production synchronization while preserving ownership drift.
restore_as_other "$DESTINATION_OTHER_URL"
restored_destination_probe="$(app_probe "$DESTINATION_APP_URL")"
if [[ "$restored_destination_probe" != '1|zebra|7' ]]; then
  echo 'Fixture restoration failed before production synchronization.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_COLLATION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'collation.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*collation' <<<"$runtime_output"; then
    echo 'NEON_COLLATION_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_COLLATION_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_collation "$DESTINATION_ADMIN_URL")"
destination_app_before_final="$(app_probe "$DESTINATION_APP_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_rename_after_output="$(rename_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_after_exit=$?
destination_app_after_final="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_final_exit=$?
set -e

printf 'AFTER\ndestination collation owner=%s\ndestination app before final owner probe=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_app_before_final" "$destination_row_2"
printf 'destination cycle_other rename exit=%s\ndestination cycle_other output=%s\n' "$destination_rename_after_exit" "$destination_rename_after_output"
printf 'destination app probe after final owner mutation exit=%s\ndestination app output=%s\nNEON_COLLATION_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final_exit" "$destination_app_after_final" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_row_2" == '2|alpha|11' && "$destination_rename_after_exit" -ne 0 && "$destination_app_after_final_exit" -eq 0 ]]; then
  echo 'NEON_COLLATION_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_COLLATION_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained collation owner authority that source assigns to a different role.' >&2
exit 1

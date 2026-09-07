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
create type public.order_status as enum ('NEW','PAID');
alter type public.order_status owner to cycle_owner;
create table public.orders (id bigint primary key, status public.order_status not null);
insert into public.orders values (1,'NEW'),(2,'PAID');
grant usage on schema public to cycle_other, cycle_app;
grant usage on type public.order_status to cycle_app;
grant select, insert on public.orders to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create type public.order_status as enum ('NEW','PAID');
alter type public.order_status owner to cycle_other;
create table public.orders (id bigint primary key, status public.order_status not null);
insert into public.orders values (1,'NEW');
grant usage on schema public to cycle_other, cycle_app;
grant usage on type public.order_status to cycle_app;
grant select, insert on public.orders to cycle_app;
SQL

owner_of_type() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(t.typowner) from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='order_status';"
}
labels_of_type() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select string_agg(e.enumlabel,',' order by e.enumsortorder) from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='order_status';"
}
rename_new_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter type public.order_status rename value 'NEW' to 'HACKED';"
}

source_owner_before="$(owner_of_type "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_type "$DESTINATION_ADMIN_URL")"
source_labels_before="$(labels_of_type "$SOURCE_ADMIN_URL")"
destination_labels_before="$(labels_of_type "$DESTINATION_ADMIN_URL")"
set +e
source_rename_output="$(rename_new_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_rename_exit=$?
destination_rename_output="$(rename_new_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_exit=$?
set -e

printf 'BEFORE\nsource enum type owner=%s\ndestination enum type owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source enum labels=%s\ndestination enum labels=%s\n' "$source_labels_before" "$destination_labels_before"
printf 'source cycle_other rename exit=%s\nsource cycle_other rename output=%s\n' "$source_rename_exit" "$source_rename_output"
printf 'destination cycle_other rename exit=%s\ndestination cycle_other rename output=%s\n' "$destination_rename_exit" "$destination_rename_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_labels_before" != 'NEW,PAID' || "$destination_labels_before" != 'NEW,PAID' || "$source_rename_exit" -eq 0 || "$destination_rename_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated enum-type ownership drift.' >&2
  exit 2
fi

# Restore disposable destination mutation so source/destination type semantics match before production sync.
psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c "alter type public.order_status rename value 'HACKED' to 'NEW';"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ENUM_TYPE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'enum|type.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*enum|type.*(incompatib|drift|mismatch)' <<<"$runtime_output"; then
    echo 'NEON_ENUM_TYPE_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ENUM_TYPE_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_type "$DESTINATION_ADMIN_URL")"
destination_labels_before_final="$(labels_of_type "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,status from public.orders where id=2;")"
set +e
destination_rename_after_output="$(rename_new_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_after_exit=$?
set -e
destination_labels_after_final="$(labels_of_type "$DESTINATION_ADMIN_URL")"
destination_app_row_1="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,status from public.orders where id=1;")"
set +e
destination_app_insert_output="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -c "insert into public.orders values (900,'HACKED') returning status;" 2>&1)"; destination_app_insert_exit=$?
set -e

printf 'AFTER\ndestination enum type owner=%s\ndestination enum labels before final owner probe=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_labels_before_final" "$destination_row_2"
printf 'destination cycle_other rename exit=%s\ndestination cycle_other rename output=%s\n' "$destination_rename_after_exit" "$destination_rename_after_output"
printf 'destination enum labels after final owner probe=%s\ndestination cycle_app row1=%s\n' "$destination_labels_after_final" "$destination_app_row_1"
printf 'destination cycle_app HACKED insert exit=%s\ndestination cycle_app HACKED insert output=%s\nNEON_ENUM_TYPE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_insert_exit" "$destination_app_insert_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_labels_before_final" == 'NEW,PAID' && "$destination_row_2" == '2|PAID' && "$destination_rename_after_exit" -ne 0 ]]; then
  echo 'NEON_ENUM_TYPE_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ENUM_TYPE_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained enum-type owner authority that source assigns to a different owner.' >&2
exit 1

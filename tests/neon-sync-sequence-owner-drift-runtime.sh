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
create sequence public.order_no_seq start with 100 increment by 1;
alter sequence public.order_no_seq owner to cycle_owner;
create table public.orders (
  id bigint primary key default nextval('public.order_no_seq'),
  note text not null
);
insert into public.orders(id,note) values
  (1,'BASE-ORDER-1'),
  (2,'SOURCE-ORDER-2');
grant usage on schema public to cycle_other, cycle_app;
grant usage, select on sequence public.order_no_seq to cycle_app;
grant select, insert on public.orders to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create sequence public.order_no_seq start with 100 increment by 1;
alter sequence public.order_no_seq owner to cycle_other;
create table public.orders (
  id bigint primary key default nextval('public.order_no_seq'),
  note text not null
);
insert into public.orders(id,note) values
  (1,'BASE-ORDER-1');
grant usage on schema public to cycle_other, cycle_app;
grant usage, select on sequence public.order_no_seq to cycle_app;
grant select, insert on public.orders to cycle_app;
SQL

owner_of_sequence() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.relowner) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='order_no_seq' and c.relkind='S';"
}
sequence_state() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select last_value,is_called from public.order_no_seq;"
}
app_row() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,note from public.orders where id=1;"
}
restart_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter sequence public.order_no_seq restart with 1;"
}
restore_sequence_100() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter sequence public.order_no_seq restart with 100;"
}
app_insert_default() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.orders(note) values ('OWNER-PROBE') returning id,note;"
}

source_owner_before="$(owner_of_sequence "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_sequence "$DESTINATION_ADMIN_URL")"
source_state_before="$(sequence_state "$SOURCE_ADMIN_URL")"
destination_state_before="$(sequence_state "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_row "$SOURCE_APP_URL")"
destination_app_before="$(app_row "$DESTINATION_APP_URL")"

set +e
source_restart_output="$(restart_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_restart_exit=$?
destination_restart_output="$(restart_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_restart_exit=$?
set -e

destination_state_mutated="$(sequence_state "$DESTINATION_ADMIN_URL")"

printf 'BEFORE\nsource sequence owner=%s\ndestination sequence owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source sequence state=%s\ndestination sequence state=%s\n' "$source_state_before" "$destination_state_before"
printf 'source app row=%s\ndestination app row=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other restart exit=%s\nsource cycle_other output=%s\n' "$source_restart_exit" "$source_restart_output"
printf 'destination cycle_other restart exit=%s\ndestination cycle_other output=%s\ndestination sequence state after owner mutation=%s\n' "$destination_restart_exit" "$destination_restart_output" "$destination_state_mutated"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_state_before" != '100|f' || "$destination_state_before" != '100|f' || "$source_app_before" != '1|BASE-ORDER-1' || "$destination_app_before" != '1|BASE-ORDER-1' || "$source_restart_exit" -eq 0 || "$destination_restart_exit" -ne 0 || "$destination_state_mutated" != '1|f' ]]; then
  echo 'Fixture did not establish isolated sequence ownership drift.' >&2
  exit 2
fi

# Restore equivalent sequence state before production synchronization while preserving ownership drift.
restore_sequence_100 "$DESTINATION_OTHER_URL"
restored_state="$(sequence_state "$DESTINATION_ADMIN_URL")"
if [[ "$restored_state" != '100|f' ]]; then
  echo 'Fixture restoration failed before production synchronization.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_SEQUENCE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'sequence.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*sequence' <<<"$runtime_output"; then
    echo 'NEON_SEQUENCE_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_SEQUENCE_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_sequence "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,note from public.orders where id=2;")"
destination_state_after_sync="$(sequence_state "$DESTINATION_ADMIN_URL")"

set +e
source_restart_after_output="$(restart_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_restart_after_exit=$?
destination_restart_after_output="$(restart_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_restart_after_exit=$?
source_insert_output="$(app_insert_default "$SOURCE_APP_URL" 2>&1)"; source_insert_exit=$?
destination_insert_output="$(app_insert_default "$DESTINATION_APP_URL" 2>&1)"; destination_insert_exit=$?
set -e

printf 'AFTER\ndestination sequence owner=%s\ndestination sequence state after sync=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_state_after_sync" "$destination_row_2"
printf 'source cycle_other restart exit=%s\nsource cycle_other output=%s\n' "$source_restart_after_exit" "$source_restart_after_output"
printf 'destination cycle_other restart exit=%s\ndestination cycle_other output=%s\n' "$destination_restart_after_exit" "$destination_restart_after_output"
printf 'source app default insert exit=%s\nsource app default insert output=%s\n' "$source_insert_exit" "$source_insert_output"
printf 'destination app default insert exit=%s\ndestination app default insert output=%s\nNEON_SEQUENCE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_insert_exit" "$destination_insert_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_row_2" == '2|SOURCE-ORDER-2' && "$source_restart_after_exit" -ne 0 && "$destination_restart_after_exit" -ne 0 && "$source_insert_exit" -eq 0 && "$destination_insert_exit" -eq 0 ]]; then
  echo 'NEON_SEQUENCE_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_row_2" == '2|SOURCE-ORDER-2' && "$source_restart_after_exit" -ne 0 && "$destination_restart_after_exit" -eq 0 && "$source_insert_exit" -eq 0 && "$destination_insert_exit" -ne 0 ]]; then
  echo 'NEON_SEQUENCE_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained sequence owner authority that source assigns to a different role; owner-only restart caused the application default insert to fail.' >&2
  exit 1
fi

echo 'Post-sync sequence ownership scenario produced an unexpected runtime state.' >&2
exit 2

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

setup_source() {
  psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create function public.retail_text_eq(text,text) returns boolean
language sql immutable strict as $$ select $1 = $2 $$;
create operator public.=== (
  leftarg = text,
  rightarg = text,
  function = public.retail_text_eq
);
alter operator public.=== (text,text) owner to cycle_owner;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'BASE-SKU-1',7),(2,'SOURCE-SKU-2',11);
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_app;
grant execute on function public.retail_text_eq(text,text) to cycle_app;
SQL
}

setup_destination() {
  psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create function public.retail_text_eq(text,text) returns boolean
language sql immutable strict as $$ select $1 = $2 $$;
create operator public.=== (
  leftarg = text,
  rightarg = text,
  function = public.retail_text_eq
);
alter operator public.=== (text,text) owner to cycle_other;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'BASE-SKU-1',7);
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_app;
grant execute on function public.retail_text_eq(text,text) to cycle_app;
SQL
}

setup_source
setup_destination

operator_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(o.oprowner) from pg_operator o join pg_namespace n on n.oid=o.oprnamespace where n.nspname='public' and o.oprname='===' and o.oprleft='text'::regtype and o.oprright='text'::regtype;"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select 'alpha'::text OPERATOR(public.===) 'alpha'::text;"
}
drop_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "drop operator public.=== (text,text);"
}
restore_destination_operator() {
  psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create operator public.=== (
  leftarg = text,
  rightarg = text,
  function = public.retail_text_eq
);
alter operator public.=== (text,text) owner to cycle_other;
SQL
}

source_owner_before="$(operator_owner "$SOURCE_ADMIN_URL")"
destination_owner_before="$(operator_owner "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"

set +e
source_drop_output="$(drop_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_exit=$?
destination_drop_output="$(drop_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_exit=$?
destination_app_after_drop_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_drop_exit=$?
set -e

printf 'BEFORE\nsource operator owner=%s\ndestination operator owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source app operator probe=%s\ndestination app operator probe=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other drop exit=%s\nsource cycle_other output=%s\n' "$source_drop_exit" "$source_drop_output"
printf 'destination cycle_other drop exit=%s\ndestination cycle_other output=%s\n' "$destination_drop_exit" "$destination_drop_output"
printf 'destination app after owner drop exit=%s\ndestination app after owner drop output=%s\n' "$destination_app_after_drop_exit" "$destination_app_after_drop_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_app_before" != t || "$destination_app_before" != t || "$source_drop_exit" -eq 0 || "$destination_drop_exit" -ne 0 || "$destination_app_after_drop_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated operator ownership drift.' >&2
  exit 2
fi

restore_destination_operator
if [[ "$(operator_owner "$DESTINATION_ADMIN_URL")" != cycle_other || "$(app_probe "$DESTINATION_APP_URL")" != t ]]; then
  echo 'Fixture restoration failed before production synchronization.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_OPERATOR_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'operator.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*operator' <<<"$runtime_output"; then
    echo 'NEON_OPERATOR_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_OPERATOR_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(operator_owner "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_app_before_final_drop="$(app_probe "$DESTINATION_APP_URL")"

set +e
source_drop_after_output="$(drop_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_after_exit=$?
destination_drop_after_output="$(drop_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_after_exit=$?
destination_app_after_final_drop_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_final_drop_exit=$?
set -e

printf 'AFTER\ndestination operator owner=%s\nappended source row=%s\ndestination app before final owner drop=%s\n' "$destination_owner_after" "$destination_row_2" "$destination_app_before_final_drop"
printf 'source cycle_other final drop exit=%s\nsource cycle_other final output=%s\n' "$source_drop_after_exit" "$source_drop_after_output"
printf 'destination cycle_other final drop exit=%s\ndestination cycle_other final output=%s\n' "$destination_drop_after_exit" "$destination_drop_after_output"
printf 'destination app after final owner drop exit=%s\ndestination app after final owner drop output=%s\nNEON_OPERATOR_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final_drop_exit" "$destination_app_after_final_drop_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -ne 0 && "$destination_app_before_final_drop" == t ]]; then
  echo 'NEON_OPERATOR_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -eq 0 && "$destination_app_before_final_drop" == t && "$destination_app_after_final_drop_exit" -ne 0 ]]; then
  echo 'NEON_OPERATOR_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained operator owner authority that source assigns to a different role; owner-only DROP broke the application operator expression.' >&2
  exit 1
fi

echo 'Post-sync operator ownership scenario produced an unexpected runtime state.' >&2
exit 2

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

setup_db() {
  local admin_url="$1" owner="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 -v owner="$owner" <<'SQL'
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
create function public.retail_sum_state(integer, integer) returns integer
  language sql immutable
  as 'select coalesce($1, 0) + coalesce($2, 0)';
create aggregate public.retail_sum(integer) (
  sfunc = public.retail_sum_state,
  stype = integer,
  initcond = '0'
);
select format('alter aggregate public.retail_sum(integer) owner to %I', :'owner') \gexec
grant usage on schema public to cycle_app, cycle_other;
grant select on public.products to cycle_app;
SQL
}

setup_db "$SOURCE_ADMIN_URL" cycle_owner
setup_db "$DESTINATION_ADMIN_URL" cycle_other
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'BASE-SKU-1',7);"

aggregate_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(p.proowner) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='retail_sum' and p.prokind='a';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select public.retail_sum(quantity) from public.products;"
}
drop_aggregate_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c 'drop aggregate public.retail_sum(integer);'
}
restore_destination_aggregate() {
  psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create aggregate public.retail_sum(integer) (
  sfunc = public.retail_sum_state,
  stype = integer,
  initcond = '0'
);
alter aggregate public.retail_sum(integer) owner to cycle_other;
SQL
}

source_owner_before="$(aggregate_owner "$SOURCE_ADMIN_URL")"
destination_owner_before="$(aggregate_owner "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"
set +e
source_drop_output="$(drop_aggregate_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_exit=$?
destination_drop_output="$(drop_aggregate_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_exit=$?
destination_app_after_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_exit=$?
set -e
printf 'BEFORE\nsource aggregate owner=%s\ndestination aggregate owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source app aggregate=%s\ndestination app aggregate=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other drop exit=%s\nsource cycle_other output=%s\n' "$source_drop_exit" "$source_drop_output"
printf 'destination cycle_other drop exit=%s\ndestination cycle_other output=%s\n' "$destination_drop_exit" "$destination_drop_output"
printf 'destination app after owner mutation exit=%s\ndestination app after owner mutation output=%s\n' "$destination_app_after_exit" "$destination_app_after_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_app_before" != 7 || "$destination_app_before" != 7 || "$source_drop_exit" -eq 0 || "$destination_drop_exit" -ne 0 || "$destination_app_after_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated aggregate ownership drift.' >&2
  exit 2
fi

restore_destination_aggregate
[[ "$(aggregate_owner "$DESTINATION_ADMIN_URL")" == cycle_other ]] || exit 2
[[ "$(app_probe "$DESTINATION_APP_URL")" == 7 ]] || exit 2
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',11);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_AGGREGATE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'aggregate.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*aggregate' <<<"$runtime_output"; then
    echo 'NEON_AGGREGATE_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_AGGREGATE_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(aggregate_owner "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_app_before_final="$(app_probe "$DESTINATION_APP_URL")"
set +e
source_drop_after_output="$(drop_aggregate_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_after_exit=$?
destination_drop_after_output="$(drop_aggregate_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_after_exit=$?
destination_app_after_final_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_final_exit=$?
set -e
printf 'AFTER\ndestination aggregate owner=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_row_2"
printf 'destination app aggregate before final owner mutation=%s\n' "$destination_app_before_final"
printf 'source cycle_other final drop exit=%s\nsource cycle_other final output=%s\n' "$source_drop_after_exit" "$source_drop_after_output"
printf 'destination cycle_other final drop exit=%s\ndestination cycle_other final output=%s\n' "$destination_drop_after_exit" "$destination_drop_after_output"
printf 'destination app after final owner mutation exit=%s\ndestination app after final owner mutation output=%s\nNEON_AGGREGATE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_after_final_exit" "$destination_app_after_final_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_app_before_final" == 18 && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -ne 0 ]]; then
  echo 'NEON_AGGREGATE_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_owner_after" == cycle_other && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_app_before_final" == 18 && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -eq 0 && "$destination_app_after_final_exit" -ne 0 ]]; then
  echo 'NEON_AGGREGATE_OWNER_DRIFT_DETECTED=false'
  echo 'Destination retained aggregate owner authority denied on source; owner-only DROP broke the real application aggregate query.' >&2
  exit 1
fi

echo 'Post-sync aggregate ownership scenario produced an unexpected runtime state.' >&2
exit 2

#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_URL='postgresql://cycle_owner:cycle@127.0.0.1:55432/cycle_d_source'
DESTINATION_URL='postgresql://cycle_owner:cycle@127.0.0.1:55433/cycle_d_destination'
SOURCE_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_source owner cycle_owner;"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_destination owner cycle_owner;"

psql "$SOURCE_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  tenant_id integer not null,
  sku text not null
);
insert into public.products values
  (1,1,'SOURCE-T1-SKU-1'),
  (2,1,'SOURCE-T1-SKU-2');
alter table public.products enable row level security;
alter table public.products force row level security;
create policy products_tenant_isolation on public.products
  using (tenant_id = current_setting('app.tenant_id')::integer)
  with check (tenant_id = current_setting('app.tenant_id')::integer);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  tenant_id integer not null,
  sku text not null
);
insert into public.products values (1,1,'SOURCE-T1-SKU-1');
alter table public.products enable row level security;
create policy products_tenant_isolation on public.products
  using (tenant_id = current_setting('app.tenant_id')::integer)
  with check (tenant_id = current_setting('app.tenant_id')::integer);
SQL

read_force_state() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='products';"
}

source_force_before="$(read_force_state "$SOURCE_POSTGRES_URL")"
destination_force_before="$(read_force_state "$DESTINATION_POSTGRES_URL")"

set +e
source_owner_forbidden_output="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (901,2,'SOURCE-OWNER-FORBIDDEN') returning id,tenant_id,sku;
SQL
)"
source_owner_forbidden_exit=$?
set -e

set +e
destination_owner_before_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (901,2,'DEST-OWNER-BYPASS-BEFORE') returning id,tenant_id,sku;
SQL
)"
destination_owner_before_exit=$?
set -e
psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -c "delete from public.products where id=901;" >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_force_after="$(read_force_state "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,tenant_id,sku from public.products where id=2;")"

set +e
destination_owner_after_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (902,2,'DEST-OWNER-BYPASS-AFTER') returning id,tenant_id,sku;
SQL
)"
destination_owner_after_exit=$?
set -e

printf 'NEON_RLS_FORCE_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_RLS_FORCE_SOURCE_BEFORE=%s\n' "$source_force_before"
printf 'NEON_RLS_FORCE_DESTINATION_BEFORE=%s\n' "$destination_force_before"
printf 'NEON_RLS_FORCE_DESTINATION_AFTER=%s\n' "$destination_force_after"
printf 'NEON_RLS_FORCE_SOURCE_OWNER_FORBIDDEN_EXIT=%s\n' "$source_owner_forbidden_exit"
printf 'NEON_RLS_FORCE_SOURCE_OWNER_FORBIDDEN_OUTPUT=%s\n' "$source_owner_forbidden_output"
printf 'NEON_RLS_FORCE_DESTINATION_OWNER_BEFORE_EXIT=%s\n' "$destination_owner_before_exit"
printf 'NEON_RLS_FORCE_DESTINATION_OWNER_BEFORE_OUTPUT=%s\n' "$destination_owner_before_output"
printf 'NEON_RLS_FORCE_DESTINATION_OWNER_AFTER_EXIT=%s\n' "$destination_owner_after_exit"
printf 'NEON_RLS_FORCE_DESTINATION_OWNER_AFTER_OUTPUT=%s\n' "$destination_owner_after_output"
printf 'NEON_RLS_FORCE_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_force_before" = 't'
test "$destination_force_before" = 'f'
test "$source_owner_forbidden_exit" -ne 0
grep -Eiq 'row-level security|policy' <<<"$source_owner_forbidden_output"
test "$destination_owner_before_exit" -eq 0
grep -Fq '901|2|DEST-OWNER-BYPASS-BEFORE' <<<"$destination_owner_before_output"

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'row.level security|force|policy|products' <<<"$runtime_output"; then
    echo 'NEON_RLS_FORCE_STATE_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_RLS_FORCE_STATE_DRIFT_DETECTED=unverified' >&2
  exit 1
fi

if [[ "$destination_force_after" = 't' ]] \
  && [[ "$destination_source_row_2" = '2|1|SOURCE-T1-SKU-2' ]] \
  && [[ "$destination_owner_after_exit" -ne 0 ]] \
  && grep -Eiq 'row-level security|policy' <<<"$destination_owner_after_output" \
  && [[ "$runtime_output" == *'Append sync and verification completed successfully for default.'* ]] \
  && [[ "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_RLS_FORCE_STATE_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_RLS_FORCE_STATE_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without converging FORCE ROW LEVEL SECURITY owner semantics.' >&2
exit 1

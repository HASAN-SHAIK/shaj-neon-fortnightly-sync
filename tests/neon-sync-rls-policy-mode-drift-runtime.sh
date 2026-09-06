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
create table public.products (id bigint primary key, tenant_id integer not null, sku text not null);
insert into public.products values (1,1,'SOURCE-T1-SKU-1'),(2,1,'SOURCE-T1-SKU-2');
alter table public.products enable row level security;
alter table public.products force row level security;
create policy products_general_access on public.products as permissive for all using (true) with check (true);
create policy products_tenant_guard on public.products as restrictive for all
  using (tenant_id = current_setting('app.tenant_id')::integer)
  with check (tenant_id = current_setting('app.tenant_id')::integer);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, tenant_id integer not null, sku text not null);
insert into public.products values (1,1,'SOURCE-T1-SKU-1');
alter table public.products enable row level security;
alter table public.products force row level security;
create policy products_general_access on public.products as permissive for all using (true) with check (true);
create policy products_tenant_guard on public.products as permissive for all
  using (tenant_id = current_setting('app.tenant_id')::integer)
  with check (tenant_id = current_setting('app.tenant_id')::integer);
SQL

read_mode() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select polpermissive from pg_policy p join pg_class c on c.oid=p.polrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='products' and p.polname='products_tenant_guard';"
}
source_mode_before="$(read_mode "$SOURCE_POSTGRES_URL")"
destination_mode_before="$(read_mode "$DESTINATION_POSTGRES_URL")"

set +e
source_forbidden_output="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (901,2,'SOURCE-CROSS-TENANT') returning id,tenant_id,sku;
SQL
)"
source_forbidden_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (901,2,'DEST-CROSS-TENANT-BEFORE') returning id,tenant_id,sku;
SQL
)"
destination_before_exit=$?
set -e
psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -c "delete from public.products where id=901;" >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_mode_after="$(read_mode "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,tenant_id,sku from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (902,2,'DEST-CROSS-TENANT-AFTER') returning id,tenant_id,sku;
SQL
)"
destination_after_exit=$?
set -e

printf 'NEON_RLS_POLICY_MODE_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_RLS_POLICY_MODE_SOURCE_BEFORE=%s\n' "$source_mode_before"
printf 'NEON_RLS_POLICY_MODE_DESTINATION_BEFORE=%s\n' "$destination_mode_before"
printf 'NEON_RLS_POLICY_MODE_DESTINATION_AFTER=%s\n' "$destination_mode_after"
printf 'NEON_RLS_POLICY_MODE_SOURCE_FORBIDDEN_EXIT=%s\n' "$source_forbidden_exit"
printf 'NEON_RLS_POLICY_MODE_SOURCE_FORBIDDEN_OUTPUT=%s\n' "$source_forbidden_output"
printf 'NEON_RLS_POLICY_MODE_DESTINATION_BEFORE_EXIT=%s\n' "$destination_before_exit"
printf 'NEON_RLS_POLICY_MODE_DESTINATION_BEFORE_OUTPUT=%s\n' "$destination_before_output"
printf 'NEON_RLS_POLICY_MODE_DESTINATION_AFTER_EXIT=%s\n' "$destination_after_exit"
printf 'NEON_RLS_POLICY_MODE_DESTINATION_AFTER_OUTPUT=%s\n' "$destination_after_output"
printf 'NEON_RLS_POLICY_MODE_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_mode_before" = 'f'
test "$destination_mode_before" = 't'
test "$source_forbidden_exit" -ne 0
grep -Eiq 'row-level security|policy' <<<"$source_forbidden_output"
test "$destination_before_exit" -eq 0
grep -Fq '901|2|DEST-CROSS-TENANT-BEFORE' <<<"$destination_before_output"

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'row.level security|restrictive|permissive|policy|products' <<<"$runtime_output"; then
    echo 'NEON_RLS_POLICY_MODE_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_RLS_POLICY_MODE_DRIFT_DETECTED=unverified' >&2
  exit 1
fi

if [[ "$destination_mode_after" = 'f' ]] \
  && [[ "$destination_source_row_2" = '2|1|SOURCE-T1-SKU-2' ]] \
  && [[ "$destination_after_exit" -ne 0 ]] \
  && grep -Eiq 'row-level security|policy' <<<"$destination_after_output" \
  && [[ "$runtime_output" == *'Append sync and verification completed successfully for default.'* ]] \
  && [[ "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_RLS_POLICY_MODE_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_RLS_POLICY_MODE_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without converging restrictive-vs-permissive RLS policy semantics.' >&2
exit 1

#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create role cycle_app login;'
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create role cycle_app login;'
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

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
create policy products_tenant_isolation on public.products
  using (tenant_id = current_setting('app.tenant_id')::integer)
  with check (tenant_id = current_setting('app.tenant_id')::integer);
grant select, insert, update, delete on public.products to cycle_app;
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
  using (true)
  with check (true);
grant select, insert, update, delete on public.products to cycle_app;
SQL

read_policy_using() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select coalesce(qual,'') from pg_policies where schemaname='public' and tablename='products' and policyname='products_tenant_isolation';"
}
read_policy_check() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select coalesce(with_check,'') from pg_policies where schemaname='public' and tablename='products' and policyname='products_tenant_isolation';"
}

source_using_before="$(read_policy_using "$SOURCE_URL")"
source_check_before="$(read_policy_check "$SOURCE_URL")"
destination_using_before="$(read_policy_using "$DESTINATION_URL")"
destination_check_before="$(read_policy_check "$DESTINATION_URL")"

set +e
source_forbidden_output="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set role cycle_app;
set app.tenant_id='1';
insert into public.products values (901,2,'SOURCE-FORBIDDEN-T2') returning id,tenant_id,sku;
SQL
)"
source_forbidden_exit=$?
set -e

set +e
destination_forbidden_before_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set role cycle_app;
set app.tenant_id='1';
insert into public.products values (901,2,'DEST-FORBIDDEN-BEFORE') returning id,tenant_id,sku;
SQL
)"
destination_forbidden_before_exit=$?
set -e
psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -c "delete from public.products where id=901;" >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_URL" DESTINATION_DATABASE_URL="$DESTINATION_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_using_after="$(read_policy_using "$DESTINATION_URL")"
destination_check_after="$(read_policy_check "$DESTINATION_URL")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,tenant_id,sku from public.products where id=2;")"

set +e
destination_forbidden_after_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set role cycle_app;
set app.tenant_id='1';
insert into public.products values (902,2,'DEST-FORBIDDEN-AFTER') returning id,tenant_id,sku;
SQL
)"
destination_forbidden_after_exit=$?
set -e

printf 'NEON_RLS_EXPR_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_RLS_EXPR_SOURCE_USING_BEFORE=%s\n' "$source_using_before"
printf 'NEON_RLS_EXPR_SOURCE_CHECK_BEFORE=%s\n' "$source_check_before"
printf 'NEON_RLS_EXPR_DESTINATION_USING_BEFORE=%s\n' "$destination_using_before"
printf 'NEON_RLS_EXPR_DESTINATION_CHECK_BEFORE=%s\n' "$destination_check_before"
printf 'NEON_RLS_EXPR_DESTINATION_USING_AFTER=%s\n' "$destination_using_after"
printf 'NEON_RLS_EXPR_DESTINATION_CHECK_AFTER=%s\n' "$destination_check_after"
printf 'NEON_RLS_EXPR_SOURCE_FORBIDDEN_EXIT=%s\n' "$source_forbidden_exit"
printf 'NEON_RLS_EXPR_SOURCE_FORBIDDEN_OUTPUT=%s\n' "$source_forbidden_output"
printf 'NEON_RLS_EXPR_DESTINATION_FORBIDDEN_BEFORE_EXIT=%s\n' "$destination_forbidden_before_exit"
printf 'NEON_RLS_EXPR_DESTINATION_FORBIDDEN_BEFORE_OUTPUT=%s\n' "$destination_forbidden_before_output"
printf 'NEON_RLS_EXPR_DESTINATION_FORBIDDEN_AFTER_EXIT=%s\n' "$destination_forbidden_after_exit"
printf 'NEON_RLS_EXPR_DESTINATION_FORBIDDEN_AFTER_OUTPUT=%s\n' "$destination_forbidden_after_output"
printf 'NEON_RLS_EXPR_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_using_before" != "$destination_using_before"
test "$source_check_before" != "$destination_check_before"
test "$source_forbidden_exit" -ne 0
grep -Eiq 'row-level security|policy' <<<"$source_forbidden_output"
test "$destination_forbidden_before_exit" -eq 0
grep -Fq '901|2|DEST-FORBIDDEN-BEFORE' <<<"$destination_forbidden_before_output"

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'row.level security|policy|products_tenant_isolation' <<<"$runtime_output"; then
    echo 'NEON_RLS_POLICY_EXPRESSION_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_RLS_POLICY_EXPRESSION_DRIFT_DETECTED=unverified' >&2
  exit 1
fi

if [[ "$destination_using_after" = "$source_using_before" ]] \
  && [[ "$destination_check_after" = "$source_check_before" ]] \
  && [[ "$destination_source_row_2" = '2|1|SOURCE-T1-SKU-2' ]] \
  && [[ "$destination_forbidden_after_exit" -ne 0 ]] \
  && grep -Eiq 'row-level security|policy' <<<"$destination_forbidden_after_output" \
  && [[ "$runtime_output" == *'Append sync and verification completed successfully for default.'* ]] \
  && [[ "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_RLS_POLICY_EXPRESSION_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_RLS_POLICY_EXPRESSION_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without converging the existing destination RLS policy expression.' >&2
exit 1

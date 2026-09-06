#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_OWNER_URL='postgresql://cycle_owner:cycle@127.0.0.1:55432/cycle_d_source'
DESTINATION_OWNER_URL='postgresql://cycle_owner:cycle@127.0.0.1:55433/cycle_d_destination'
SOURCE_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_source owner cycle_owner;"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_destination owner cycle_owner;"

psql "$SOURCE_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, tenant_id integer not null, sku text not null);
insert into public.products values (1,1,'SOURCE-T1-SKU-1'),(2,1,'SOURCE-T1-SKU-2');
alter table public.products enable row level security;
create policy products_tenant_isolation on public.products as permissive for all to cycle_app
  using (tenant_id = current_setting('app.tenant_id')::integer)
  with check (tenant_id = current_setting('app.tenant_id')::integer);
grant select, insert on public.products to cycle_app, cycle_other;
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, tenant_id integer not null, sku text not null);
insert into public.products values (1,1,'SOURCE-T1-SKU-1');
alter table public.products enable row level security;
create policy products_tenant_isolation on public.products as permissive for all to public
  using (tenant_id = current_setting('app.tenant_id')::integer)
  with check (tenant_id = current_setting('app.tenant_id')::integer);
grant select, insert on public.products to cycle_app, cycle_other;
SQL

read_roles() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "
    select string_agg(case when role_oid = 0 then 'PUBLIC' else pg_get_userbyid(role_oid) end, ',' order by ord)
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral unnest(p.polroles) with ordinality as r(role_oid, ord)
    where n.nspname='public' and c.relname='products' and p.polname='products_tenant_isolation';"
}

source_roles_before="$(read_roles "$SOURCE_POSTGRES_URL")"
destination_roles_before="$(read_roles "$DESTINATION_POSTGRES_URL")"

set +e
source_other_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (901,1,'SOURCE-OTHER-FORBIDDEN') returning id,tenant_id,sku;
SQL
)"
source_other_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (901,1,'DEST-OTHER-BEFORE') returning id,tenant_id,sku;
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

destination_roles_after="$(read_roles "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,tenant_id,sku from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -F '|' <<'SQL' 2>&1
set app.tenant_id='1';
insert into public.products values (902,1,'DEST-OTHER-AFTER') returning id,tenant_id,sku;
SQL
)"
destination_after_exit=$?
set -e

printf 'NEON_RLS_POLICY_ROLE_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_RLS_POLICY_ROLE_SOURCE_BEFORE=%s\n' "$source_roles_before"
printf 'NEON_RLS_POLICY_ROLE_DESTINATION_BEFORE=%s\n' "$destination_roles_before"
printf 'NEON_RLS_POLICY_ROLE_DESTINATION_AFTER=%s\n' "$destination_roles_after"
printf 'NEON_RLS_POLICY_ROLE_SOURCE_OTHER_EXIT=%s\n' "$source_other_exit"
printf 'NEON_RLS_POLICY_ROLE_SOURCE_OTHER_OUTPUT=%s\n' "$source_other_output"
printf 'NEON_RLS_POLICY_ROLE_DESTINATION_BEFORE_EXIT=%s\n' "$destination_before_exit"
printf 'NEON_RLS_POLICY_ROLE_DESTINATION_BEFORE_OUTPUT=%s\n' "$destination_before_output"
printf 'NEON_RLS_POLICY_ROLE_DESTINATION_AFTER_EXIT=%s\n' "$destination_after_exit"
printf 'NEON_RLS_POLICY_ROLE_DESTINATION_AFTER_OUTPUT=%s\n' "$destination_after_output"
printf 'NEON_RLS_POLICY_ROLE_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_roles_before" = 'cycle_app'
test "$destination_roles_before" = 'PUBLIC'
test "$source_other_exit" -ne 0
grep -Eiq 'row-level security|policy' <<<"$source_other_output"
test "$destination_before_exit" -eq 0
grep -Fq '901|1|DEST-OTHER-BEFORE' <<<"$destination_before_output"

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'row.level security|policy|role|products_tenant_isolation|products' <<<"$runtime_output"; then
    echo 'NEON_RLS_POLICY_ROLE_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_RLS_POLICY_ROLE_DRIFT_DETECTED=unverified' >&2
  exit 1
fi

if [[ "$destination_roles_after" = 'cycle_app' ]] \
  && [[ "$destination_source_row_2" = '2|1|SOURCE-T1-SKU-2' ]] \
  && [[ "$destination_after_exit" -ne 0 ]] \
  && grep -Eiq 'row-level security|policy' <<<"$destination_after_output" \
  && [[ "$runtime_output" == *'Append sync and verification completed successfully for default.'* ]] \
  && [[ "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_RLS_POLICY_ROLE_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_RLS_POLICY_ROLE_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without converging RLS policy role membership.' >&2
exit 1

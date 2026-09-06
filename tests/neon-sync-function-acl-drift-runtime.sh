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
  psql "$admin_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_source owner cycle_owner;"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "create database cycle_d_destination owner cycle_owner;"

psql "$SOURCE_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.protected_config (id integer primary key, secret_value text not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
insert into public.protected_config values (1,'cycle-d-protected-value');
revoke all on table public.protected_config from public;
create function public.read_protected_config()
returns text
language sql
security definer
set search_path = public
as $$ select secret_value from public.protected_config where id = 1 $$;
revoke all on function public.read_protected_config() from public;
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.protected_config (id integer primary key, secret_value text not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
insert into public.protected_config values (1,'cycle-d-protected-value');
revoke all on table public.protected_config from public;
create function public.read_protected_config()
returns text
language sql
security definer
set search_path = public
as $$ select secret_value from public.protected_config where id = 1 $$;
revoke all on function public.read_protected_config() from public;
grant execute on function public.read_protected_config() to cycle_other;
SQL

has_execute_privilege() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select has_function_privilege('cycle_other','public.read_protected_config()','EXECUTE');"
}

source_execute_before="$(has_execute_privilege "$SOURCE_POSTGRES_URL")"
destination_execute_before="$(has_execute_privilege "$DESTINATION_POSTGRES_URL")"
source_direct_select="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.protected_config','SELECT');")"
destination_direct_select="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.protected_config','SELECT');")"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "select public.read_protected_config();" 2>&1)"
source_before_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "select public.read_protected_config();" 2>&1)"
destination_before_exit=$?
set -e

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_execute_after="$(has_execute_privilege "$DESTINATION_POSTGRES_URL")"
destination_direct_select_after="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.protected_config','SELECT');")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "select public.read_protected_config();" 2>&1)"
destination_after_exit=$?
set -e

printf 'NEON_FUNCTION_ACL_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_FUNCTION_ACL_SOURCE_EXECUTE_BEFORE=%s\n' "$source_execute_before"
printf 'NEON_FUNCTION_ACL_DESTINATION_EXECUTE_BEFORE=%s\n' "$destination_execute_before"
printf 'NEON_FUNCTION_ACL_SOURCE_DIRECT_SELECT=%s\n' "$source_direct_select"
printf 'NEON_FUNCTION_ACL_DESTINATION_DIRECT_SELECT=%s\n' "$destination_direct_select"
printf 'NEON_FUNCTION_ACL_SOURCE_PROBE_EXIT=%s\n' "$source_before_exit"
printf 'NEON_FUNCTION_ACL_SOURCE_PROBE_OUTPUT=%s\n' "$source_before_output"
printf 'NEON_FUNCTION_ACL_DESTINATION_BEFORE_EXIT=%s\n' "$destination_before_exit"
printf 'NEON_FUNCTION_ACL_DESTINATION_BEFORE_OUTPUT=%s\n' "$destination_before_output"
printf 'NEON_FUNCTION_ACL_DESTINATION_EXECUTE_AFTER=%s\n' "$destination_execute_after"
printf 'NEON_FUNCTION_ACL_DESTINATION_DIRECT_SELECT_AFTER=%s\n' "$destination_direct_select_after"
printf 'NEON_FUNCTION_ACL_DESTINATION_AFTER_EXIT=%s\n' "$destination_after_exit"
printf 'NEON_FUNCTION_ACL_DESTINATION_AFTER_OUTPUT=%s\n' "$destination_after_output"
printf 'NEON_FUNCTION_ACL_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_execute_before" = 'f'
test "$destination_execute_before" = 't'
test "$source_direct_select" = 'f'
test "$destination_direct_select" = 'f'
test "$source_before_exit" -ne 0
grep -Eiq 'permission denied|privilege' <<<"$source_before_output"
test "$destination_before_exit" -eq 0
test "$destination_before_output" = 'cycle-d-protected-value'

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'function|execute|grant|privilege|acl|permission|read_protected_config' <<<"$runtime_output"; then
    echo 'NEON_FUNCTION_ACL_DRIFT_SAFE_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'Production sync failed, but not for an explicit function ACL/privilege incompatibility reason.' >&2
  exit 1
fi

test "$destination_source_row_2" = '2|SOURCE-SKU-2|11'
test "$destination_direct_select_after" = 'f'

if [[ "$destination_execute_after" = 'f' && "$destination_after_exit" -ne 0 ]] && \
   grep -Eiq 'permission denied|privilege' <<<"$destination_after_output"; then
  echo 'NEON_FUNCTION_ACL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_FUNCTION_ACL_DRIFT_DETECTED=false'
echo 'Destination retained a source-absent function EXECUTE privilege while production sync reported success.' >&2
exit 1

#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_POSTGRES_URL="$SOURCE_ADMIN_URL"
DESTINATION_POSTGRES_URL="$DESTINATION_ADMIN_URL"
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
alter table public.products owner to cycle_owner;
revoke all on table public.products from public;
revoke all on table public.products from cycle_other;
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
alter table public.products owner to cycle_other;
revoke all on table public.products from public;
insert into public.products values (1,'SOURCE-SKU-1',7);
SQL

owner_of_products() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.relowner) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='products' and c.relkind='r';"
}

cycle_other_insert_privilege() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select has_table_privilege('cycle_other','public.products','INSERT');"
}

source_owner_before="$(owner_of_products "$SOURCE_POSTGRES_URL")"
destination_owner_before="$(owner_of_products "$DESTINATION_POSTGRES_URL")"
source_insert_priv_before="$(cycle_other_insert_privilege "$SOURCE_POSTGRES_URL")"
destination_insert_priv_before="$(cycle_other_insert_privilege "$DESTINATION_POSTGRES_URL")"
source_acl_before="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select coalesce(relacl::text,'<NULL>') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='products';")"
destination_acl_before="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select coalesce(relacl::text,'<NULL>') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='products';")"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (901,'SOURCE-OTHER-FORBIDDEN',1);" 2>&1)"
source_before_exit=$?
set -e

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (901,'DEST-OWNER-BEFORE',1);" 2>&1)"
destination_before_exit=$?
set -e

printf 'BEFORE\n'
printf 'source owner=%s\n' "$source_owner_before"
printf 'destination owner=%s\n' "$destination_owner_before"
printf 'source cycle_other INSERT privilege=%s\n' "$source_insert_priv_before"
printf 'destination cycle_other INSERT privilege=%s\n' "$destination_insert_priv_before"
printf 'source relacl=%s\n' "$source_acl_before"
printf 'destination relacl=%s\n' "$destination_acl_before"
printf 'source cycle_other INSERT exit=%s\n' "$source_before_exit"
printf 'source cycle_other INSERT output=%s\n' "$source_before_output"
printf 'destination cycle_other INSERT exit=%s\n' "$destination_before_exit"
printf 'destination cycle_other INSERT output=%s\n' "$destination_before_output"

if [[ "$source_owner_before" != 'cycle_owner' || "$destination_owner_before" != 'cycle_other' || "$source_insert_priv_before" != 'f' || "$destination_insert_priv_before" != 't' || "$source_before_exit" -eq 0 || "$destination_before_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated table ownership drift.' >&2
  exit 2
fi

# Remove the successful destination probe so business rows are comparable before sync.
psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -c 'delete from public.products where id=901;'

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

# Explicit fail-closed handling of ownership incompatibility is safe.
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_TABLE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi '(owner|ownership).*(incompatib|drift|mismatch|permission)|(incompatib|drift|mismatch).*(owner|ownership)' <<<"$runtime_output"; then
    echo 'NEON_TABLE_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_TABLE_OWNER_DRIFT_FAIL_CLOSED=false'
  echo 'Production sync failed for a reason not identified as table ownership incompatibility.' >&2
  exit 1
fi

destination_owner_after="$(owner_of_products "$DESTINATION_POSTGRES_URL")"
destination_insert_priv_after="$(cycle_other_insert_privilege "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (902,'DEST-OWNER-AFTER',1);" 2>&1)"
destination_after_exit=$?
set -e

destination_probe_row="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=902;")"

printf 'AFTER\n'
printf 'destination owner=%s\n' "$destination_owner_after"
printf 'destination cycle_other INSERT privilege=%s\n' "$destination_insert_priv_after"
printf 'appended source row=%s\n' "$destination_source_row_2"
printf 'destination cycle_other INSERT exit=%s\n' "$destination_after_exit"
printf 'destination cycle_other INSERT output=%s\n' "$destination_after_output"
printf 'destination probe row=%s\n' "$destination_probe_row"
printf 'NEON_TABLE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

# Safe convergence requires source ownership semantics on destination, the valid
# source append, and rejection of the same non-owner write that source rejects.
if [[ "$destination_owner_after" == 'cycle_owner' && "$destination_insert_priv_after" == 'f' && "$destination_after_exit" -ne 0 && -z "$destination_probe_row" && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_TABLE_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_TABLE_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained table ownership authority that source assigns to a different role.' >&2
exit 1

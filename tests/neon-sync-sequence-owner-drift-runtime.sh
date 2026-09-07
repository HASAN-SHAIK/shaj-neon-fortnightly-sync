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
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
create sequence public.invoice_no_seq start with 1000;
select setval('public.invoice_no_seq',1000,false);
alter sequence public.invoice_no_seq owner to cycle_owner;
revoke all on sequence public.invoice_no_seq from public;
revoke all on sequence public.invoice_no_seq from cycle_other;
grant usage on schema public to cycle_other;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
create sequence public.invoice_no_seq start with 1000;
select setval('public.invoice_no_seq',1000,false);
alter sequence public.invoice_no_seq owner to cycle_other;
revoke all on sequence public.invoice_no_seq from public;
grant usage on schema public to cycle_other;
SQL

owner_of_sequence() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.relowner) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='invoice_no_seq' and c.relkind='S';"
}

cycle_other_usage_privilege() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "select has_sequence_privilege('cycle_other','public.invoice_no_seq','USAGE');"
}

sequence_last_value() {
  local url="$1"
  psql "$url" -v ON_ERROR_STOP=1 -Atc 'select last_value from public.invoice_no_seq;'
}

source_owner_before="$(owner_of_sequence "$SOURCE_POSTGRES_URL")"
destination_owner_before="$(owner_of_sequence "$DESTINATION_POSTGRES_URL")"
source_usage_before="$(cycle_other_usage_privilege "$SOURCE_POSTGRES_URL")"
destination_usage_before="$(cycle_other_usage_privilege "$DESTINATION_POSTGRES_URL")"
source_acl_before="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select coalesce(c.relacl::text,'<NULL>') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='invoice_no_seq';")"
destination_acl_before="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select coalesce(c.relacl::text,'<NULL>') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='invoice_no_seq';")"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -Atc "select nextval('public.invoice_no_seq');" 2>&1)"
source_before_exit=$?
set -e
set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -Atc "select nextval('public.invoice_no_seq');" 2>&1)"
destination_before_exit=$?
set -e

printf 'BEFORE\n'
printf 'source sequence owner=%s\n' "$source_owner_before"
printf 'destination sequence owner=%s\n' "$destination_owner_before"
printf 'source cycle_other USAGE privilege=%s\n' "$source_usage_before"
printf 'destination cycle_other USAGE privilege=%s\n' "$destination_usage_before"
printf 'source relacl=%s\n' "$source_acl_before"
printf 'destination relacl=%s\n' "$destination_acl_before"
printf 'source cycle_other nextval exit=%s\n' "$source_before_exit"
printf 'source cycle_other nextval output=%s\n' "$source_before_output"
printf 'destination cycle_other nextval exit=%s\n' "$destination_before_exit"
printf 'destination cycle_other nextval output=%s\n' "$destination_before_output"

if [[ "$source_owner_before" != 'cycle_owner' || "$destination_owner_before" != 'cycle_other' || "$source_usage_before" != 'f' || "$destination_usage_before" != 't' || "$source_before_exit" -eq 0 || "$destination_before_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated sequence ownership drift.' >&2
  exit 2
fi

# Restore destination sequence state after the successful pre-sync ownership probe.
psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -c "select setval('public.invoice_no_seq',1000,false);" >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

# Explicit fail-closed handling of ownership incompatibility is safe.
if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_SEQUENCE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi '(sequence).*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*(sequence).*(incompatib|drift|mismatch)|(incompatib|drift|mismatch).*(sequence).*(owner|ownership)' <<<"$runtime_output"; then
    echo 'NEON_SEQUENCE_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_SEQUENCE_OWNER_DRIFT_FAIL_CLOSED=false'
  echo 'Production sync failed for a reason not identified as sequence ownership incompatibility.' >&2
  exit 1
fi

destination_owner_after="$(owner_of_sequence "$DESTINATION_POSTGRES_URL")"
destination_usage_after="$(cycle_other_usage_privilege "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_sequence_before_probe="$(sequence_last_value "$DESTINATION_POSTGRES_URL")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -Atc "select nextval('public.invoice_no_seq');" 2>&1)"
destination_after_exit=$?
set -e

printf 'AFTER\n'
printf 'destination sequence owner=%s\n' "$destination_owner_after"
printf 'destination cycle_other USAGE privilege=%s\n' "$destination_usage_after"
printf 'destination sequence last_value before probe=%s\n' "$destination_sequence_before_probe"
printf 'appended source row=%s\n' "$destination_source_row_2"
printf 'destination cycle_other nextval exit=%s\n' "$destination_after_exit"
printf 'destination cycle_other nextval output=%s\n' "$destination_after_output"
printf 'NEON_SEQUENCE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

# Safe convergence requires source ownership semantics on destination, the valid
# source append, and rejection of the same non-owner sequence mutation source rejects.
if [[ "$destination_owner_after" == 'cycle_owner' && "$destination_usage_after" == 'f' && "$destination_after_exit" -ne 0 && "$destination_source_row_2" == '2|SOURCE-SKU-2|11' ]]; then
  echo 'NEON_SEQUENCE_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_SEQUENCE_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained sequence ownership authority that source assigns to a different role.' >&2
exit 1

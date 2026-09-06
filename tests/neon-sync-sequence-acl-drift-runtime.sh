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
create sequence public.invoice_no_seq start with 1000 increment by 1;
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
revoke all on sequence public.invoice_no_seq from public;
SQL

psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create sequence public.invoice_no_seq start with 1000 increment by 1;
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
revoke all on sequence public.invoice_no_seq from public;
grant usage on sequence public.invoice_no_seq to cycle_other;
SQL

has_usage_privilege() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select has_sequence_privilege('cycle_other','public.invoice_no_seq','USAGE');"
}

source_usage_before="$(has_usage_privilege "$SOURCE_POSTGRES_URL")"
destination_usage_before="$(has_usage_privilege "$DESTINATION_POSTGRES_URL")"

set +e
source_before_output="$(psql "$SOURCE_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "select nextval('public.invoice_no_seq');" 2>&1)"
source_before_exit=$?
set -e
source_seq_after_probe="$(psql "$SOURCE_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select last_value from public.invoice_no_seq;")"

set +e
destination_before_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "select nextval('public.invoice_no_seq');" 2>&1)"
destination_before_exit=$?
set -e
destination_seq_after_probe="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select last_value from public.invoice_no_seq;")"

# Restore identical sequence state before invoking production sync.
psql "$DESTINATION_OWNER_URL" -v ON_ERROR_STOP=1 -c "select setval('public.invoice_no_seq', 1000, false);" >/dev/null
destination_seq_restored="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select last_value from public.invoice_no_seq;")"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_POSTGRES_URL" DESTINATION_DATABASE_URL="$DESTINATION_POSTGRES_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"
sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

destination_usage_after="$(has_usage_privilege "$DESTINATION_POSTGRES_URL")"
destination_source_row_2="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

set +e
destination_after_output="$(psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -At -c "select nextval('public.invoice_no_seq');" 2>&1)"
destination_after_exit=$?
set -e
destination_seq_after="$(psql "$DESTINATION_POSTGRES_URL" -v ON_ERROR_STOP=1 -Atc "select last_value from public.invoice_no_seq;")"

printf 'NEON_SEQUENCE_ACL_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_SEQUENCE_ACL_SOURCE_USAGE_BEFORE=%s\n' "$source_usage_before"
printf 'NEON_SEQUENCE_ACL_DESTINATION_USAGE_BEFORE=%s\n' "$destination_usage_before"
printf 'NEON_SEQUENCE_ACL_SOURCE_PROBE_EXIT=%s\n' "$source_before_exit"
printf 'NEON_SEQUENCE_ACL_SOURCE_PROBE_OUTPUT=%s\n' "$source_before_output"
printf 'NEON_SEQUENCE_ACL_SOURCE_SEQUENCE_AFTER_PROBE=%s\n' "$source_seq_after_probe"
printf 'NEON_SEQUENCE_ACL_DESTINATION_BEFORE_EXIT=%s\n' "$destination_before_exit"
printf 'NEON_SEQUENCE_ACL_DESTINATION_BEFORE_OUTPUT=%s\n' "$destination_before_output"
printf 'NEON_SEQUENCE_ACL_DESTINATION_SEQUENCE_AFTER_PROBE=%s\n' "$destination_seq_after_probe"
printf 'NEON_SEQUENCE_ACL_DESTINATION_SEQUENCE_RESTORED=%s\n' "$destination_seq_restored"
printf 'NEON_SEQUENCE_ACL_DESTINATION_USAGE_AFTER=%s\n' "$destination_usage_after"
printf 'NEON_SEQUENCE_ACL_DESTINATION_AFTER_EXIT=%s\n' "$destination_after_exit"
printf 'NEON_SEQUENCE_ACL_DESTINATION_AFTER_OUTPUT=%s\n' "$destination_after_output"
printf 'NEON_SEQUENCE_ACL_DESTINATION_SEQUENCE_AFTER=%s\n' "$destination_seq_after"
printf 'NEON_SEQUENCE_ACL_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"

test "$source_usage_before" = 'f'
test "$destination_usage_before" = 't'
test "$source_before_exit" -ne 0
grep -Eiq 'permission denied|privilege' <<<"$source_before_output"
test "$source_seq_after_probe" = '1000'
test "$destination_before_exit" -eq 0
test "$destination_before_output" = '1000'
test "$destination_seq_after_probe" = '1000'
test "$destination_seq_restored" = '1000'

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'sequence|grant|privilege|acl|permission|invoice_no_seq' <<<"$runtime_output"; then
    echo 'NEON_SEQUENCE_ACL_DRIFT_SAFE_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'Production sync failed, but not for an explicit sequence ACL/privilege incompatibility reason.' >&2
  exit 1
fi

test "$destination_source_row_2" = '2|SOURCE-SKU-2|11'

if [[ "$destination_usage_after" = 'f' && "$destination_after_exit" -ne 0 ]] && \
   grep -Eiq 'permission denied|privilege' <<<"$destination_after_output" && \
   [[ "$destination_seq_after" = '1000' ]]; then
  echo 'NEON_SEQUENCE_ACL_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_SEQUENCE_ACL_DRIFT_DETECTED=false'
echo 'Destination retained a source-absent sequence USAGE privilege while production sync reported success.' >&2
exit 1

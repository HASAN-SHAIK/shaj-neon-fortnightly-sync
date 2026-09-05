#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PORT="55434"
DEST_PORT="55435"
SOURCE_MASTER_DB="cycle_d_source_master_missing_tenant"
DEST_MASTER_DB="cycle_d_dest_master_missing_tenant"
TENANT_DB="cycle_d_missing_source_tenant"
SOURCE_ADMIN_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/postgres"
DEST_ADMIN_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/postgres"
SOURCE_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/${SOURCE_MASTER_DB}"
DEST_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/${DEST_MASTER_DB}"
LOG_FILE="$(mktemp)"

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

createdb --maintenance-db="$SOURCE_ADMIN_URL" "$SOURCE_MASTER_DB"
createdb --maintenance-db="$DEST_ADMIN_URL" "$DEST_MASTER_DB"

psql "$SOURCE_MASTER_URL" -v ON_ERROR_STOP=1 <<SQL
create table public.tenants (
  id bigint primary key,
  database_name text not null unique
);
insert into public.tenants (id, database_name) values (1, '${TENANT_DB}');
SQL

psql "$DEST_MASTER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.destination_guard (
  id bigint primary key,
  value text not null
);
insert into public.destination_guard (id, value) values (1, 'destination-master-baseline');
SQL

if psql "$SOURCE_ADMIN_URL" -Atc 'select datname from pg_database;' | grep -Fxq "$TENANT_DB"; then
  echo "Source tenant database unexpectedly exists before scenario." >&2
  exit 1
fi
if psql "$DEST_ADMIN_URL" -Atc 'select datname from pg_database;' | grep -Fxq "$TENANT_DB"; then
  echo "Destination tenant database unexpectedly exists before scenario." >&2
  exit 1
fi

registry_before="$(psql "$DEST_MASTER_URL" -Atc "select count(*) from information_schema.tables where table_schema='public' and table_name='tenants';")"
guard_before="$(psql "$DEST_MASTER_URL" -Atc "select value from public.destination_guard where id=1;")"
echo "NEON_MISSING_TENANT_DEST_REGISTRY_TABLE_BEFORE=$registry_before"
echo "NEON_MISSING_TENANT_DEST_DB_BEFORE=0"
echo "NEON_MISSING_TENANT_GUARD_BEFORE=$guard_before"

set +e
SOURCE_MASTER_DATABASE_URL="$SOURCE_MASTER_URL" \
DESTINATION_MASTER_DATABASE_URL="$DEST_MASTER_URL" \
NOTIFY_EMAIL_TO='' \
RENDER_API_KEY='' \
RENDER_SERVICE_IDS='' \
RENDER_ENV_GROUP_ID='' \
  bash "$ROOT_DIR/scripts/neon-sync/append-sync.sh" >"$LOG_FILE" 2>&1
sync_exit=$?
set -e

cat "$LOG_FILE"
echo "NEON_MISSING_TENANT_SYNC_EXIT=$sync_exit"

# Target failure must be the advertised tenant's missing source database.
test "$sync_exit" -ne 0
grep -Fq 'Discovering tenant databases from source master database...' "$LOG_FILE"
grep -Fq 'Discovered tenant databases: 1' "$LOG_FILE"
grep -Fq 'Append sync and verification completed successfully for masterdb.' "$LOG_FILE"
grep -Fq "Ensuring destination database exists for ${TENANT_DB}..." "$LOG_FILE"
grep -Fq "Checking source connection for ${TENANT_DB}..." "$LOG_FILE"
grep -Eq "database .*${TENANT_DB}.* does not exist|FATAL:.*${TENANT_DB}" "$LOG_FILE"

registry_table_after="$(psql "$DEST_MASTER_URL" -Atc "select count(*) from information_schema.tables where table_schema='public' and table_name='tenants';")"
if [[ "$registry_table_after" = '1' ]]; then
  registry_rows_after="$(psql "$DEST_MASTER_URL" -Atc "select count(*) from public.tenants where database_name='${TENANT_DB}';")"
else
  registry_rows_after='0'
fi
dest_tenant_after="$(psql "$DEST_ADMIN_URL" -Atc "select count(*) from pg_database where datname='${TENANT_DB}';")"
guard_after="$(psql "$DEST_MASTER_URL" -Atc "select value from public.destination_guard where id=1;")"

echo "NEON_MISSING_TENANT_DEST_REGISTRY_TABLE_AFTER=$registry_table_after"
echo "NEON_MISSING_TENANT_DEST_REGISTRY_ROWS_AFTER=$registry_rows_after"
echo "NEON_MISSING_TENANT_DEST_DB_AFTER=$dest_tenant_after"
echo "NEON_MISSING_TENANT_GUARD_AFTER=$guard_after"
echo "NEON_MISSING_TENANT_PROCESS_FAILED=true"

test "$guard_after" = "$guard_before"

# Fail-closed orchestration invariant: an advertised but unavailable source tenant
# must not be committed into destination master state or provision an empty
# destination tenant database before its source database is proven reachable.
if [[ "$registry_rows_after" != '0' || "$dest_tenant_after" != '0' ]]; then
  echo "NEON_MISSING_SOURCE_TENANT_FAIL_CLOSED=false" >&2
  echo "Partial destination mutation occurred before source tenant validation: registry_rows=${registry_rows_after}, destination_db=${dest_tenant_after}" >&2
  exit 1
fi

echo 'NEON_MISSING_SOURCE_TENANT_FAIL_CLOSED=true'

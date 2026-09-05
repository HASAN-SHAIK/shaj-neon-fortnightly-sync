#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PORT="55432"
DEST_PORT="55433"
SOURCE_MASTER_DB="cycle_d_source_master"
DEST_MASTER_DB="cycle_d_dest_master"
TENANT_DB="cycle_d_tenant_01"
SOURCE_ADMIN_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/postgres"
DEST_ADMIN_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/postgres"
SOURCE_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/${SOURCE_MASTER_DB}"
DEST_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/${DEST_MASTER_DB}"
SOURCE_TENANT_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/${TENANT_DB}"
DEST_TENANT_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/${TENANT_DB}"
LOG_FILE="$(mktemp)"

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

createdb --maintenance-db="$SOURCE_ADMIN_URL" "$SOURCE_MASTER_DB"
createdb --maintenance-db="$DEST_ADMIN_URL" "$DEST_MASTER_DB"
createdb --maintenance-db="$SOURCE_ADMIN_URL" "$TENANT_DB"

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

psql "$SOURCE_TENANT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null unique,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (101, 'TENANT-SKU-101', 7),
  (102, 'TENANT-SKU-102', 11);
SQL

if psql "$DEST_ADMIN_URL" -Atc 'select datname from pg_database;' | grep -Fxq "$TENANT_DB"; then
  echo "Destination tenant database unexpectedly existed before sync." >&2
  exit 1
fi

guard_before="$(psql "$DEST_MASTER_URL" -Atc "select value from public.destination_guard where id=1;")"

SOURCE_MASTER_DATABASE_URL="$SOURCE_MASTER_URL" \
DESTINATION_MASTER_DATABASE_URL="$DEST_MASTER_URL" \
NOTIFY_EMAIL_TO='' \
RENDER_API_KEY='' \
RENDER_SERVICE_IDS='' \
RENDER_ENV_GROUP_ID='' \
  bash "$ROOT_DIR/scripts/neon-sync/append-sync.sh" >"$LOG_FILE" 2>&1

cat "$LOG_FILE"

dest_tenant_exists="$(psql "$DEST_ADMIN_URL" -Atc "select count(*) from pg_database where datname='${TENANT_DB}';")"
master_tenant_count="$(psql "$DEST_MASTER_URL" -Atc "select count(*) from public.tenants where database_name='${TENANT_DB}';")"
tenant_row_count="$(psql "$DEST_TENANT_URL" -Atc 'select count(*) from public.products;')"
tenant_rows="$(psql "$DEST_TENANT_URL" -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"
guard_after="$(psql "$DEST_MASTER_URL" -Atc "select value from public.destination_guard where id=1;")"

echo "NEON_TENANT_DEST_DB_EXISTS=$dest_tenant_exists"
echo "NEON_TENANT_MASTER_REGISTRY_ROWS=$master_tenant_count"
echo "NEON_TENANT_PRODUCT_ROWS=$tenant_row_count"
echo "NEON_TENANT_PRODUCT_DATA=$tenant_rows"
echo "NEON_TENANT_DEST_GUARD_BEFORE=$guard_before"
echo "NEON_TENANT_DEST_GUARD_AFTER=$guard_after"

grep -Fq 'Discovering tenant databases from source master database...' "$LOG_FILE"
grep -Fq 'Discovered tenant databases: 1' "$LOG_FILE"
grep -Fq 'Sync masterdb' "$LOG_FILE"
grep -Fq "Ensuring destination database exists for ${TENANT_DB}..." "$LOG_FILE"
grep -Fq "Sync ${TENANT_DB}" "$LOG_FILE"
grep -Fq "Append sync and verification completed successfully for ${TENANT_DB}." "$LOG_FILE"
grep -Fq 'All configured Neon database syncs completed successfully.' "$LOG_FILE"

test "$dest_tenant_exists" = '1'
test "$master_tenant_count" = '1'
test "$tenant_row_count" = '2'
test "$tenant_rows" = $'101|TENANT-SKU-101|7\n102|TENANT-SKU-102|11'
test "$guard_before" = 'destination-master-baseline'
test "$guard_after" = "$guard_before"

echo 'NEON_TENANT_DISCOVERY_CREATE_RUNTIME_PASS=true'

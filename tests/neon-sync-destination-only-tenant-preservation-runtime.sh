#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PORT="55432"
DEST_PORT="55433"
SOURCE_MASTER_DB="cycle_d_source_master"
DEST_MASTER_DB="cycle_d_dest_master"
ORPHAN_TENANT_DB="cycle_d_destination_only_tenant"
SOURCE_ADMIN_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/postgres"
DEST_ADMIN_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/postgres"
SOURCE_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/${SOURCE_MASTER_DB}"
DEST_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/${DEST_MASTER_DB}"
DEST_TENANT_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/${ORPHAN_TENANT_DB}"
LOG_FILE="$(mktemp)"

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

createdb --maintenance-db="$SOURCE_ADMIN_URL" "$SOURCE_MASTER_DB"
createdb --maintenance-db="$DEST_ADMIN_URL" "$DEST_MASTER_DB"
createdb --maintenance-db="$DEST_ADMIN_URL" "$ORPHAN_TENANT_DB"

psql "$SOURCE_MASTER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.tenants (
  id bigint primary key,
  database_name text not null unique
);
SQL

psql "$DEST_MASTER_URL" -v ON_ERROR_STOP=1 <<SQL
create table public.tenants (
  id bigint primary key,
  database_name text not null unique
);
insert into public.tenants (id, database_name)
values (91, '${ORPHAN_TENANT_DB}');

create table public.destination_guard (
  id bigint primary key,
  value text not null
);
insert into public.destination_guard (id, value)
values (1, 'destination-master-baseline');
SQL

psql "$DEST_TENANT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null unique,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (901, 'DEST-ONLY-SKU-901', 17),
  (902, 'DEST-ONLY-SKU-902', 23);
SQL

source_registry_before="$(psql "$SOURCE_MASTER_URL" -Atc 'select count(*) from public.tenants;')"
dest_registry_before="$(psql "$DEST_MASTER_URL" -Atc "select count(*) from public.tenants where database_name='${ORPHAN_TENANT_DB}';")"
dest_tenant_rows_before="$(psql "$DEST_TENANT_URL" -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"
guard_before="$(psql "$DEST_MASTER_URL" -Atc 'select value from public.destination_guard where id=1;')"

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
echo "NEON_DEST_ONLY_TENANT_SYNC_EXIT=$sync_exit"
test "$sync_exit" = '0'

source_registry_after="$(psql "$SOURCE_MASTER_URL" -Atc 'select count(*) from public.tenants;')"
dest_registry_after="$(psql "$DEST_MASTER_URL" -Atc "select count(*) from public.tenants where database_name='${ORPHAN_TENANT_DB}';")"
dest_tenant_db_after="$(psql "$DEST_ADMIN_URL" -Atc "select count(*) from pg_database where datname='${ORPHAN_TENANT_DB}';")"
dest_tenant_rows_after="$(psql "$DEST_TENANT_URL" -At -F '|' -c 'select id, sku, quantity from public.products order by id;')"
guard_after="$(psql "$DEST_MASTER_URL" -Atc 'select value from public.destination_guard where id=1;')"

echo "NEON_DEST_ONLY_SOURCE_REGISTRY_BEFORE=$source_registry_before"
echo "NEON_DEST_ONLY_SOURCE_REGISTRY_AFTER=$source_registry_after"
echo "NEON_DEST_ONLY_DEST_REGISTRY_BEFORE=$dest_registry_before"
echo "NEON_DEST_ONLY_DEST_REGISTRY_AFTER=$dest_registry_after"
echo "NEON_DEST_ONLY_DEST_DB_AFTER=$dest_tenant_db_after"
echo "NEON_DEST_ONLY_TENANT_ROWS_BEFORE=$dest_tenant_rows_before"
echo "NEON_DEST_ONLY_TENANT_ROWS_AFTER=$dest_tenant_rows_after"
echo "NEON_DEST_ONLY_GUARD_BEFORE=$guard_before"
echo "NEON_DEST_ONLY_GUARD_AFTER=$guard_after"

grep -Fq 'Discovering tenant databases from source master database...' "$LOG_FILE"
grep -Fq 'Configured database pairs: 1' "$LOG_FILE"
grep -Fq 'Discovered tenant databases: 0' "$LOG_FILE"
grep -Fq 'Sync masterdb' "$LOG_FILE"
grep -Fq 'Append sync and verification completed successfully for masterdb.' "$LOG_FILE"
grep -Fq 'All configured Neon database syncs completed successfully.' "$LOG_FILE"

if grep -Fq "Ensuring destination database exists for ${ORPHAN_TENANT_DB}..." "$LOG_FILE"; then
  echo "Production unexpectedly attempted destination-only tenant provisioning." >&2
  exit 1
fi
if grep -Fq "Sync ${ORPHAN_TENANT_DB}" "$LOG_FILE"; then
  echo "Production unexpectedly attempted to sync a tenant absent from the source registry." >&2
  exit 1
fi

test "$source_registry_before" = '0'
test "$source_registry_after" = '0'
test "$dest_registry_before" = '1'
test "$dest_registry_after" = '1'
test "$dest_tenant_db_after" = '1'
test "$dest_tenant_rows_before" = $'901|DEST-ONLY-SKU-901|17\n902|DEST-ONLY-SKU-902|23'
test "$dest_tenant_rows_after" = "$dest_tenant_rows_before"
test "$guard_before" = 'destination-master-baseline'
test "$guard_after" = "$guard_before"

echo 'NEON_DESTINATION_ONLY_TENANT_PRESERVATION_RUNTIME_PASS=true'

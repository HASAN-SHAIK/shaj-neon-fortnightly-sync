#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PORT="55432"
DEST_PORT="55433"
SOURCE_MASTER_DB="cycle_d_reserved_source_master"
DEST_MASTER_DB="cycle_d_reserved_dest_master"
TENANT_DB='cycle/d%tenant'
SOURCE_ADMIN_HOST="127.0.0.1"
DEST_ADMIN_HOST="127.0.0.1"
SOURCE_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${SOURCE_PORT}/${SOURCE_MASTER_DB}"
DEST_MASTER_URL="postgresql://postgres:postgres@127.0.0.1:${DEST_PORT}/${DEST_MASTER_DB}"
LOG_FILE="$(mktemp)"
DEST_BEFORE="$(mktemp)"
DEST_AFTER="$(mktemp)"
NEW_DATABASES="$(mktemp)"

cleanup() {
  rm -f "$LOG_FILE" "$DEST_BEFORE" "$DEST_AFTER" "$NEW_DATABASES"
}
trap cleanup EXIT

createdb -h "$SOURCE_ADMIN_HOST" -p "$SOURCE_PORT" -U postgres "$SOURCE_MASTER_DB"
createdb -h "$DEST_ADMIN_HOST" -p "$DEST_PORT" -U postgres "$DEST_MASTER_DB"
createdb -h "$SOURCE_ADMIN_HOST" -p "$SOURCE_PORT" -U postgres "$TENANT_DB"

psql "$SOURCE_MASTER_URL" -v ON_ERROR_STOP=1 -v tenant_db="$TENANT_DB" <<'SQL'
create table public.tenants (
  id bigint primary key,
  database_name text not null unique
);
insert into public.tenants (id, database_name) values (1, :'tenant_db');
SQL

psql "$DEST_MASTER_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.destination_guard (
  id bigint primary key,
  value text not null
);
insert into public.destination_guard (id, value) values (1, 'destination-master-baseline');
SQL

psql -h "$SOURCE_ADMIN_HOST" -p "$SOURCE_PORT" -U postgres -d "$TENANT_DB" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null unique,
  quantity integer not null
);
insert into public.products (id, sku, quantity) values
  (801, 'RESERVED-SKU-801', 19),
  (802, 'RESERVED-SKU-802', 31);
SQL

psql -h "$DEST_ADMIN_HOST" -p "$DEST_PORT" -U postgres -d postgres -Atc 'select datname from pg_database order by datname;' > "$DEST_BEFORE"
if grep -Fxq "$TENANT_DB" "$DEST_BEFORE"; then
  echo "Destination tenant database unexpectedly existed before sync." >&2
  exit 1
fi

guard_before="$(psql "$DEST_MASTER_URL" -Atc "select value from public.destination_guard where id=1;")"

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
echo "NEON_RESERVED_TENANT_LITERAL=$TENANT_DB"
echo "NEON_RESERVED_TENANT_SYNC_EXIT=$sync_exit"

psql -h "$DEST_ADMIN_HOST" -p "$DEST_PORT" -U postgres -d postgres -Atc 'select datname from pg_database order by datname;' > "$DEST_AFTER"
comm -13 "$DEST_BEFORE" "$DEST_AFTER" > "$NEW_DATABASES"
new_database_count="$(wc -l < "$NEW_DATABASES" | tr -d ' ')"
new_database_name="$(cat "$NEW_DATABASES")"
dest_tenant_exists="$(grep -Fxc "$TENANT_DB" "$DEST_AFTER" || true)"
master_tenant_count="$(psql "$DEST_MASTER_URL" -v tenant_db="$TENANT_DB" -At <<'SQL'
select count(*) from public.tenants where database_name = :'tenant_db';
SQL
)"
guard_after="$(psql "$DEST_MASTER_URL" -Atc "select value from public.destination_guard where id=1;")"

tenant_row_count='UNAVAILABLE'
tenant_rows='UNAVAILABLE'
if [[ "$dest_tenant_exists" == '1' ]]; then
  tenant_row_count="$(psql -h "$DEST_ADMIN_HOST" -p "$DEST_PORT" -U postgres -d "$TENANT_DB" -Atc "select count(*) from public.products;" 2>/dev/null || echo 'MISSING_PRODUCTS')"
  tenant_rows="$(psql -h "$DEST_ADMIN_HOST" -p "$DEST_PORT" -U postgres -d "$TENANT_DB" -At -F '|' -c 'select id, sku, quantity from public.products order by id;' 2>/dev/null || echo 'MISSING_PRODUCTS')"
fi

echo "NEON_RESERVED_TENANT_DEST_DB_EXISTS=$dest_tenant_exists"
echo "NEON_RESERVED_TENANT_NEW_DB_COUNT=$new_database_count"
echo "NEON_RESERVED_TENANT_NEW_DB_NAME=$new_database_name"
echo "NEON_RESERVED_TENANT_MASTER_ROWS=$master_tenant_count"
echo "NEON_RESERVED_TENANT_PRODUCT_ROWS=$tenant_row_count"
echo "NEON_RESERVED_TENANT_PRODUCT_DATA=$tenant_rows"
echo "NEON_RESERVED_TENANT_GUARD_BEFORE=$guard_before"
echo "NEON_RESERVED_TENANT_GUARD_AFTER=$guard_after"

grep -Fq 'Discovering tenant databases from source master database...' "$LOG_FILE"
grep -Fq 'Discovered tenant databases: 1' "$LOG_FILE"

test "$sync_exit" = '0'
test "$dest_tenant_exists" = '1'
test "$new_database_count" = '1'
test "$new_database_name" = "$TENANT_DB"
test "$master_tenant_count" = '1'
test "$tenant_row_count" = '2'
test "$tenant_rows" = $'801|RESERVED-SKU-801|19\n802|RESERVED-SKU-802|31'
test "$guard_before" = 'destination-master-baseline'
test "$guard_after" = "$guard_before"
grep -Fq "Ensuring destination database exists for ${TENANT_DB}..." "$LOG_FILE"
grep -Fq "Sync ${TENANT_DB}" "$LOG_FILE"
grep -Fq "Append sync and verification completed successfully for ${TENANT_DB}." "$LOG_FILE"
grep -Fq 'All configured Neon database syncs completed successfully.' "$LOG_FILE"

echo 'NEON_TENANT_URL_RESERVED_RUNTIME_PASS=true'

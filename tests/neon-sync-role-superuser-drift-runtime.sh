#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' nosuperuser;"
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app' superuser;"
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
create table public.admin_secrets (
  id bigint primary key,
  secret_value text not null
);
revoke all on public.admin_secrets from public;
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
insert into public.admin_secrets values (1,'CYCLE-D-ADMIN-SECRET');
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

superuser_flag() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolsuper from pg_roles where rolname='cycle_app';"
}
protected_read() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select secret_value from public.admin_secrets where id=1;"
}

source_super_before="$(superuser_flag "$SOURCE_ADMIN_URL")"
destination_super_before="$(superuser_flag "$DESTINATION_ADMIN_URL")"
set +e
source_read_output="$(protected_read "$SOURCE_APP_URL" 2>&1)"; source_read_exit=$?
destination_read_output="$(protected_read "$DESTINATION_APP_URL" 2>&1)"; destination_read_exit=$?
set -e

printf 'BEFORE\nsource cycle_app rolsuper=%s\ndestination cycle_app rolsuper=%s\n' "$source_super_before" "$destination_super_before"
printf 'source protected read exit=%s\nsource output=%s\n' "$source_read_exit" "$source_read_output"
printf 'destination protected read exit=%s\ndestination output=%s\n' "$destination_read_exit" "$destination_read_output"

if [[ "$source_super_before" != f || "$destination_super_before" != t || "$source_read_exit" -eq 0 || "$destination_read_exit" -ne 0 || "$destination_read_output" != 'CYCLE-D-ADMIN-SECRET' ]]; then
  echo 'Fixture did not establish isolated role SUPERUSER drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_SUPERUSER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'rolsuper|superuser|role.*attribute' <<<"$runtime_output"; then
    echo 'NEON_ROLE_SUPERUSER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_SUPERUSER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_super_after="$(superuser_flag "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_read_after_output="$(protected_read "$DESTINATION_APP_URL" 2>&1)"; destination_read_after_exit=$?
set -e

printf 'AFTER\ndestination cycle_app rolsuper=%s\nappended source row=%s\n' "$destination_super_after" "$destination_row_2"
printf 'destination protected read exit=%s\ndestination output=%s\nNEON_ROLE_SUPERUSER_DRIFT_SYNC_EXIT=%s\n' "$destination_read_after_exit" "$destination_read_after_output" "$sync_exit"

if [[ "$destination_super_after" == f && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_read_after_exit" -ne 0 ]]; then
  echo 'NEON_ROLE_SUPERUSER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_SUPERUSER_DRIFT_DETECTED=false'
exit 1

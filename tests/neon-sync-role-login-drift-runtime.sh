#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app nologin password 'app';
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'app';
create database cycle_d_destination;
SQL

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
grant select on public.products to cycle_app;
SQL
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
grant select on public.products to cycle_app;
SQL

role_canlogin() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolcanlogin from pg_roles where rolname='cycle_app';"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products order by id;"
}

source_attr_before="$(role_canlogin "$SOURCE_ADMIN_URL")"
destination_attr_before="$(role_canlogin "$DESTINATION_ADMIN_URL")"
set +e
source_probe_output="$(app_probe "$SOURCE_APP_URL" 2>&1)"; source_probe_exit=$?
destination_probe_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_probe_exit=$?
set -e

printf 'BEFORE\nsource cycle_app rolcanlogin=%s\ndestination cycle_app rolcanlogin=%s\n' "$source_attr_before" "$destination_attr_before"
printf 'source cycle_app connection/select exit=%s\nsource output=%s\n' "$source_probe_exit" "$source_probe_output"
printf 'destination cycle_app connection/select exit=%s\ndestination output=%s\n' "$destination_probe_exit" "$destination_probe_output"

if [[ "$source_attr_before" != f || "$destination_attr_before" != t || "$source_probe_exit" -eq 0 || "$destination_probe_exit" -ne 0 || "$destination_probe_output" != '1|SOURCE-SKU-1|7' ]]; then
  echo 'Fixture did not establish isolated LOGIN drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_LOGIN_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'rolcanlogin|\b(login|nologin)\b|role.*attribute.*(drift|mismatch|incompatib)' <<<"$runtime_output"; then
    echo 'NEON_ROLE_LOGIN_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_LOGIN_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_attr_after="$(role_canlogin "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_probe_after_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_probe_after_exit=$?
set -e

printf 'AFTER\ndestination cycle_app rolcanlogin=%s\nappended source row=%s\n' "$destination_attr_after" "$destination_row_2"
printf 'destination cycle_app connection/select exit=%s\ndestination output=%s\n' "$destination_probe_after_exit" "$destination_probe_after_output"
printf 'NEON_ROLE_LOGIN_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"

if [[ "$destination_attr_after" == f && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_probe_after_exit" -ne 0 ]]; then
  echo 'NEON_ROLE_LOGIN_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_LOGIN_DRIFT_DETECTED=false'
echo 'Destination retained LOGIN capability that source denies.' >&2
exit 1

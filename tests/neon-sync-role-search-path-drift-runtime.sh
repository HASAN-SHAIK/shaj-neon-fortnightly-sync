#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:cycle-app-password@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:cycle-app-password@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-app-password';
alter role cycle_app set search_path = public;
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login password 'cycle-app-password';
alter role cycle_app set search_path = attacker, public;
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
create schema attacker;
create table attacker.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
grant usage on schema public, attacker to cycle_app;
grant select on public.products, attacker.products to cycle_app;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
insert into attacker.products values (1,'ATTACKER-SHADOW',999);
SQL
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
insert into public.products values (1,'SOURCE-SKU-1',7);
insert into attacker.products values (1,'ATTACKER-SHADOW',999);
SQL

probe_unqualified() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from products where id=1;"
}

source_setting="$(psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -At -c "select coalesce(array_to_string(setconfig,','),'') from pg_db_role_setting s join pg_roles r on r.oid=s.setrole where r.rolname='cycle_app' and s.setdatabase=0;")"
destination_setting="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -c "select coalesce(array_to_string(setconfig,','),'') from pg_db_role_setting s join pg_roles r on r.oid=s.setrole where r.rolname='cycle_app' and s.setdatabase=0;")"
source_output="$(probe_unqualified "$SOURCE_APP_URL")"
destination_output="$(probe_unqualified "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\n' "$source_setting" "$destination_setting"
printf 'source unqualified output=%s\ndestination unqualified output=%s\n' "$source_output" "$destination_output"

if [[ "$source_setting" != 'search_path=public' || "$destination_setting" != 'search_path=attacker, public' || "$source_output" != '1|SOURCE-SKU-1|7' || "$destination_output" != '1|ATTACKER-SHADOW|999' ]]; then
  echo 'Fixture did not establish isolated role search_path drift.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_SEARCH_PATH_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'search_path|pg_db_role_setting|role setting' <<<"$runtime_output"; then
    echo 'NEON_ROLE_SEARCH_PATH_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_SEARCH_PATH_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_setting_after="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -c "select coalesce(array_to_string(setconfig,','),'') from pg_db_role_setting s join pg_roles r on r.oid=s.setrole where r.rolname='cycle_app' and s.setdatabase=0;")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
destination_output_after="$(probe_unqualified "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination role setting=%s\nappended source row=%s\ndestination unqualified output=%s\nNEON_ROLE_SEARCH_PATH_DRIFT_SYNC_EXIT=%s\n' "$destination_setting_after" "$destination_row_2" "$destination_output_after" "$sync_exit"

if [[ "$destination_setting_after" == 'search_path=public' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_output_after" == '1|SOURCE-SKU-1|7' ]]; then
  echo 'NEON_ROLE_SEARCH_PATH_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_SEARCH_PATH_DRIFT_DETECTED=false'
exit 1

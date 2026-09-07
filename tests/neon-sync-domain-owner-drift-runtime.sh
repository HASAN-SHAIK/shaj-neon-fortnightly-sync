#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create domain public.nonnegative_qty as integer constraint nonnegative_qty_check check (value >= 0);
alter domain public.nonnegative_qty owner to cycle_owner;
create table public.products (id bigint primary key, sku text not null, quantity public.nonnegative_qty not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
grant usage on schema public to cycle_other, cycle_app;
grant usage on domain public.nonnegative_qty to cycle_app;
grant select, insert on public.products to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create domain public.nonnegative_qty as integer constraint nonnegative_qty_check check (value >= 0);
alter domain public.nonnegative_qty owner to cycle_other;
create table public.products (id bigint primary key, sku text not null, quantity public.nonnegative_qty not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
grant usage on schema public to cycle_other, cycle_app;
grant usage on domain public.nonnegative_qty to cycle_app;
grant select, insert on public.products to cycle_app;
SQL

owner_of_domain() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(t.typowner) from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='nonnegative_qty' and t.typtype='d';"
}
constraint_exists() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint c join pg_type t on t.oid=c.contypid join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='nonnegative_qty' and c.conname='nonnegative_qty_check';"
}
drop_constraint_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter domain public.nonnegative_qty drop constraint nonnegative_qty_check;"
}

source_owner_before="$(owner_of_domain "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_domain "$DESTINATION_ADMIN_URL")"
source_constraint_before="$(constraint_exists "$SOURCE_ADMIN_URL")"
destination_constraint_before="$(constraint_exists "$DESTINATION_ADMIN_URL")"
set +e
source_drop_output="$(drop_constraint_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_exit=$?
destination_drop_output="$(drop_constraint_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_exit=$?
set -e

printf 'BEFORE\nsource domain owner=%s\ndestination domain owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source constraint count=%s\ndestination constraint count=%s\n' "$source_constraint_before" "$destination_constraint_before"
printf 'source cycle_other drop constraint exit=%s\nsource cycle_other output=%s\n' "$source_drop_exit" "$source_drop_output"
printf 'destination cycle_other drop constraint exit=%s\ndestination cycle_other output=%s\n' "$destination_drop_exit" "$destination_drop_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_constraint_before" != 1 || "$destination_constraint_before" != 1 || "$source_drop_exit" -eq 0 || "$destination_drop_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated domain ownership drift.' >&2
  exit 2
fi

# Restore the disposable destination mutation before production sync while preserving ownership drift.
psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c "alter domain public.nonnegative_qty add constraint nonnegative_qty_check check (value >= 0);"

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_DOMAIN_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'domain.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*domain' <<<"$runtime_output"; then
    echo 'NEON_DOMAIN_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_DOMAIN_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_domain "$DESTINATION_ADMIN_URL")"
destination_constraint_before_final="$(constraint_exists "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_drop_after_output="$(drop_constraint_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_after_exit=$?
set -e
destination_constraint_after_final="$(constraint_exists "$DESTINATION_ADMIN_URL")"
set +e
destination_app_bad_insert_output="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -c "insert into public.products values (900,'INVALID-NEGATIVE',-1) returning quantity;" 2>&1)"; destination_app_bad_insert_exit=$?
set -e

printf 'AFTER\ndestination domain owner=%s\ndestination constraint before final owner probe=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_constraint_before_final" "$destination_row_2"
printf 'destination cycle_other drop constraint exit=%s\ndestination cycle_other output=%s\n' "$destination_drop_after_exit" "$destination_drop_after_output"
printf 'destination constraint after final owner probe=%s\n' "$destination_constraint_after_final"
printf 'destination cycle_app negative insert exit=%s\ndestination cycle_app negative insert output=%s\nNEON_DOMAIN_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_app_bad_insert_exit" "$destination_app_bad_insert_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_constraint_before_final" == 1 && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_drop_after_exit" -ne 0 && "$destination_app_bad_insert_exit" -ne 0 ]]; then
  echo 'NEON_DOMAIN_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_DOMAIN_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained domain-owner authority that source assigns to a different owner.' >&2
exit 1

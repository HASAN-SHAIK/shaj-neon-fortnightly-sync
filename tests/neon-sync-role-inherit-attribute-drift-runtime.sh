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
create role privileged_writer nologin;
create role cycle_app login noinherit password 'app';
create database cycle_d_source;
SQL
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 <<'SQL'
create role privileged_writer nologin;
create role cycle_app login inherit password 'app';
create database cycle_d_destination;
SQL

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
grant insert on public.products to privileged_writer;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

role_inherit() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select rolinherit from pg_roles where rolname='cycle_app';"
}
membership_inherit() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select m.inherit_option from pg_auth_members m join pg_roles r on r.oid=m.roleid join pg_roles u on u.oid=m.member where r.rolname='privileged_writer' and u.rolname='cycle_app';"
}
probe_insert() {
  local url="$1" id="$2" sku="$3"
  psql "$url" -v ON_ERROR_STOP=1 -Atc "insert into public.products(id,sku,quantity) values ($id,'$sku',1);"
}

source_role_before="$(role_inherit "$SOURCE_ADMIN_URL")"
destination_role_before="$(role_inherit "$DESTINATION_ADMIN_URL")"

# PostgreSQL uses the member role's INHERIT attribute as the default membership
# INHERIT option when GRANT ROLE omits WITH INHERIT. Exercise that real future
# authorization behavior on both clusters, then remove the disposable memberships.
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app;' >/dev/null
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app;' >/dev/null
source_membership_before="$(membership_inherit "$SOURCE_ADMIN_URL")"
destination_membership_before="$(membership_inherit "$DESTINATION_ADMIN_URL")"
set +e
source_insert_output="$(probe_insert "$SOURCE_APP_URL" 901 SOURCE-INHERIT-PROBE 2>&1)"; source_insert_exit=$?
destination_insert_output="$(probe_insert "$DESTINATION_APP_URL" 901 DEST-INHERIT-PROBE 2>&1)"; destination_insert_exit=$?
set -e

printf 'BEFORE\nsource role rolinherit=%s\ndestination role rolinherit=%s\n' "$source_role_before" "$destination_role_before"
printf 'source default membership inherit_option=%s\ndestination default membership inherit_option=%s\n' "$source_membership_before" "$destination_membership_before"
printf 'source inherited insert exit=%s\nsource output=%s\n' "$source_insert_exit" "$source_insert_output"
printf 'destination inherited insert exit=%s\ndestination output=%s\n' "$destination_insert_exit" "$destination_insert_output"

if [[ "$source_role_before" != f || "$destination_role_before" != t || "$source_membership_before" != f || "$destination_membership_before" != t || "$source_insert_exit" -eq 0 || "$destination_insert_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated role-level INHERIT attribute drift.' >&2
  exit 2
fi
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'delete from public.products where id=901;' >/dev/null
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'revoke privileged_writer from cycle_app;' >/dev/null
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'revoke privileged_writer from cycle_app;' >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_INHERIT_ATTRIBUTE_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'rolinherit|role.*inherit|inherit.*role' <<<"$runtime_output"; then
    echo 'NEON_ROLE_INHERIT_ATTRIBUTE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_INHERIT_ATTRIBUTE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_role_after="$(role_inherit "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"

# Repeat the real default-membership behavior after production sync.
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app;' >/dev/null
destination_membership_after="$(membership_inherit "$DESTINATION_ADMIN_URL")"
set +e
destination_insert_after_output="$(probe_insert "$DESTINATION_APP_URL" 902 DEST-INHERIT-AFTER 2>&1)"; destination_insert_after_exit=$?
set -e
destination_probe_count="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -Atc 'select count(*) from public.products where id=902;')"

printf 'AFTER\ndestination role rolinherit=%s\ndestination default membership inherit_option=%s\nappended source row=%s\n' "$destination_role_after" "$destination_membership_after" "$destination_row_2"
printf 'destination inherited insert exit=%s\ndestination output=%s\ndestination probe row count=%s\nNEON_ROLE_INHERIT_ATTRIBUTE_DRIFT_SYNC_EXIT=%s\n' "$destination_insert_after_exit" "$destination_insert_after_output" "$destination_probe_count" "$sync_exit"

if [[ "$destination_role_after" == f && "$destination_membership_after" == f && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_insert_after_exit" -ne 0 && "$destination_probe_count" == 0 ]]; then
  echo 'NEON_ROLE_INHERIT_ATTRIBUTE_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_INHERIT_ATTRIBUTE_DRIFT_DETECTED=false'
exit 1

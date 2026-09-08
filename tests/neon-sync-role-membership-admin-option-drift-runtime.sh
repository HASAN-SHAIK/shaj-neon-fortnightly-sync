#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 <<'SQL'
create role privileged_writer nologin;
create role delegated_user nologin;
create role cycle_app login password 'app';
SQL
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app with admin false, inherit false, set false;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'grant privileged_writer to cycle_app with admin true, inherit false, set false;'
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

for admin_url in "$SOURCE_ADMIN_URL" "$DESTINATION_ADMIN_URL"; do
  psql "$admin_url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null
);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL
done
psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);"
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (1,'SOURCE-SKU-1',7);"

membership_options() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select m.admin_option,m.inherit_option,m.set_option from pg_auth_members m join pg_roles r on r.oid=m.roleid join pg_roles u on u.oid=m.member where r.rolname='privileged_writer' and u.rolname='cycle_app';"
}
delegated_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_auth_members m join pg_roles r on r.oid=m.roleid join pg_roles u on u.oid=m.member where r.rolname='privileged_writer' and u.rolname='delegated_user';"
}
probe_delegate() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc 'grant privileged_writer to delegated_user;'
}

source_options_before="$(membership_options "$SOURCE_ADMIN_URL")"
destination_options_before="$(membership_options "$DESTINATION_ADMIN_URL")"
set +e
source_delegate_output="$(probe_delegate "$SOURCE_APP_URL" 2>&1)"; source_delegate_exit=$?
destination_delegate_output="$(probe_delegate "$DESTINATION_APP_URL" 2>&1)"; destination_delegate_exit=$?
set -e
source_delegated_before="$(delegated_count "$SOURCE_ADMIN_URL")"
destination_delegated_before="$(delegated_count "$DESTINATION_ADMIN_URL")"

printf 'BEFORE\nsource membership admin|inherit|set=%s\ndestination membership admin|inherit|set=%s\n' "$source_options_before" "$destination_options_before"
printf 'source delegate grant exit=%s\nsource delegate output=%s\n' "$source_delegate_exit" "$source_delegate_output"
printf 'destination delegate grant exit=%s\ndestination delegate output=%s\n' "$destination_delegate_exit" "$destination_delegate_output"
printf 'source delegated membership count=%s\ndestination delegated membership count=%s\n' "$source_delegated_before" "$destination_delegated_before"

if [[ "$source_options_before" != 'f|f|f' || "$destination_options_before" != 't|f|f' || "$source_delegate_exit" -eq 0 || "$destination_delegate_exit" -ne 0 || "$source_delegated_before" != 0 || "$destination_delegated_before" != 1 ]]; then
  echo 'Fixture did not establish isolated membership ADMIN-option drift.' >&2
  exit 2
fi
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'revoke privileged_writer from delegated_user;' >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_ROLE_MEMBERSHIP_ADMIN_OPTION_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'admin_option|membership.*admin|role.*membership' <<<"$runtime_output"; then
    echo 'NEON_ROLE_MEMBERSHIP_ADMIN_OPTION_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_MEMBERSHIP_ADMIN_OPTION_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_options_after="$(membership_options "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2;")"
set +e
destination_delegate_after_output="$(probe_delegate "$DESTINATION_APP_URL" 2>&1)"; destination_delegate_after_exit=$?
set -e
destination_delegated_after="$(delegated_count "$DESTINATION_ADMIN_URL")"

printf 'AFTER\ndestination membership admin|inherit|set=%s\nappended source row=%s\n' "$destination_options_after" "$destination_row_2"
printf 'destination delegate grant exit=%s\ndestination delegate output=%s\ndestination delegated membership count=%s\nNEON_ROLE_MEMBERSHIP_ADMIN_OPTION_DRIFT_SYNC_EXIT=%s\n' "$destination_delegate_after_exit" "$destination_delegate_after_output" "$destination_delegated_after" "$sync_exit"

if [[ "$destination_options_after" == 'f|f|f' && "$destination_row_2" == '2|SOURCE-SKU-2|11' && "$destination_delegate_after_exit" -ne 0 && "$destination_delegated_after" == 0 ]]; then
  echo 'NEON_ROLE_MEMBERSHIP_ADMIN_OPTION_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_ROLE_MEMBERSHIP_ADMIN_OPTION_DRIFT_DETECTED=false'
exit 1

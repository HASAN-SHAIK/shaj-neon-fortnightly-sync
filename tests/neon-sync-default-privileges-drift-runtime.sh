#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ROOT='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DEST_ROOT='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_ADMIN='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DEST_ADMIN='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OWNER='postgresql://cycle_owner:cycle@127.0.0.1:55432/cycle_d_source'
DEST_OWNER='postgresql://cycle_owner:cycle@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DEST_OTHER='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'

for root in "$SOURCE_ROOT" "$DEST_ROOT"; do
  psql "$root" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
done
psql "$SOURCE_ROOT" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source owner cycle_owner;'
psql "$DEST_ROOT" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination owner cycle_owner;'

for db in "$SOURCE_ADMIN" "$DEST_ADMIN"; do
  psql "$db" -v ON_ERROR_STOP=1 -c 'grant usage on schema public to cycle_other;'
done

psql "$SOURCE_OWNER" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7),(2,'SOURCE-SKU-2',11);
alter default privileges for role cycle_owner in schema public revoke insert on tables from cycle_other;
SQL

psql "$DEST_OWNER" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products values (1,'SOURCE-SKU-1',7);
alter default privileges for role cycle_owner in schema public grant insert on tables to cycle_other;
SQL

default_insert_priv() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select coalesce(bool_or(x.privilege_type='INSERT' and x.grantee='cycle_other'),false) from pg_default_acl d cross join lateral aclexplode(d.defaclacl) a join pg_roles g on g.oid=a.grantee cross join lateral (select g.rolname::text as grantee, case a.privilege_type when 'a' then 'INSERT' else a.privilege_type::text end as privilege_type) x where d.defaclrole=(select oid from pg_roles where rolname='cycle_owner') and d.defaclnamespace=(select oid from pg_namespace where nspname='public') and d.defaclobjtype='r';"
}

# PostgreSQL's aclitem privilege code for INSERT is 'a'; use has_table_privilege on actual future tables as the authoritative runtime check.
source_default="$(psql "$SOURCE_ADMIN" -v ON_ERROR_STOP=1 -Atc "select coalesce(array_to_string(defaclacl,','),'') from pg_default_acl where defaclrole=(select oid from pg_roles where rolname='cycle_owner') and defaclnamespace=(select oid from pg_namespace where nspname='public') and defaclobjtype='r';")"
dest_default="$(psql "$DEST_ADMIN" -v ON_ERROR_STOP=1 -Atc "select coalesce(array_to_string(defaclacl,','),'') from pg_default_acl where defaclrole=(select oid from pg_roles where rolname='cycle_owner') and defaclnamespace=(select oid from pg_namespace where nspname='public') and defaclobjtype='r';")"

psql "$SOURCE_OWNER" -v ON_ERROR_STOP=1 -c 'create table public.future_before(id integer);'
psql "$DEST_OWNER" -v ON_ERROR_STOP=1 -c 'create table public.future_before(id integer);'
set +e
source_before_output="$(psql "$SOURCE_OTHER" -v ON_ERROR_STOP=1 -c 'insert into public.future_before values (1);' 2>&1)"; source_before_exit=$?
dest_before_output="$(psql "$DEST_OTHER" -v ON_ERROR_STOP=1 -c 'insert into public.future_before values (1);' 2>&1)"; dest_before_exit=$?
set -e

printf 'BEFORE\nsource default acl=%s\ndestination default acl=%s\n' "$source_default" "$dest_default"
printf 'source future-table insert exit=%s\nsource output=%s\n' "$source_before_exit" "$source_before_output"
printf 'destination future-table insert exit=%s\ndestination output=%s\n' "$dest_before_exit" "$dest_before_output"

if [[ "$source_before_exit" -eq 0 || "$dest_before_exit" -ne 0 ]]; then
  echo 'Fixture did not establish isolated default-privileges drift.' >&2
  exit 2
fi
psql "$SOURCE_OWNER" -v ON_ERROR_STOP=1 -c 'drop table public.future_before;'
psql "$DEST_OWNER" -v ON_ERROR_STOP=1 -c 'drop table public.future_before;'

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN" DESTINATION_DATABASE_URL="$DEST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_DEFAULT_PRIVILEGES_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'default privileges|default acl|pg_default_acl|privilege.*(drift|mismatch|incompatib)' <<<"$runtime_output"; then
    echo 'NEON_DEFAULT_PRIVILEGES_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_DEFAULT_PRIVILEGES_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

source_default_after="$(psql "$SOURCE_ADMIN" -v ON_ERROR_STOP=1 -Atc "select coalesce(array_to_string(defaclacl,','),'') from pg_default_acl where defaclrole=(select oid from pg_roles where rolname='cycle_owner') and defaclnamespace=(select oid from pg_namespace where nspname='public') and defaclobjtype='r';")"
dest_default_after="$(psql "$DEST_ADMIN" -v ON_ERROR_STOP=1 -Atc "select coalesce(array_to_string(defaclacl,','),'') from pg_default_acl where defaclrole=(select oid from pg_roles where rolname='cycle_owner') and defaclnamespace=(select oid from pg_namespace where nspname='public') and defaclobjtype='r';")"
appended="$(psql "$DEST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=2;')"
psql "$SOURCE_OWNER" -v ON_ERROR_STOP=1 -c 'create table public.future_after(id integer);'
psql "$DEST_OWNER" -v ON_ERROR_STOP=1 -c 'create table public.future_after(id integer);'
set +e
source_after_output="$(psql "$SOURCE_OTHER" -v ON_ERROR_STOP=1 -c 'insert into public.future_after values (2);' 2>&1)"; source_after_exit=$?
dest_after_output="$(psql "$DEST_OTHER" -v ON_ERROR_STOP=1 -c 'insert into public.future_after values (2);' 2>&1)"; dest_after_exit=$?
set -e

printf 'AFTER\nsource default acl=%s\ndestination default acl=%s\nappended source row=%s\n' "$source_default_after" "$dest_default_after" "$appended"
printf 'source future-table insert exit=%s\nsource output=%s\n' "$source_after_exit" "$source_after_output"
printf 'destination future-table insert exit=%s\ndestination output=%s\nNEON_DEFAULT_PRIVILEGES_DRIFT_SYNC_EXIT=%s\n' "$dest_after_exit" "$dest_after_output" "$sync_exit"

if [[ "$appended" == '2|SOURCE-SKU-2|11' && "$source_after_exit" -ne 0 && "$dest_after_exit" -ne 0 ]]; then
  echo 'NEON_DEFAULT_PRIVILEGES_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_DEFAULT_PRIVILEGES_DRIFT_DETECTED=false'
echo 'Destination retained source-absent default INSERT privileges for future tables.' >&2
exit 1

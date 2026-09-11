#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_ADMIN_URL='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SOURCE_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55432/cycle_d_source'
DESTINATION_OTHER_URL='postgresql://cycle_other:other@127.0.0.1:55433/cycle_d_destination'
SOURCE_APP_URL='postgresql://cycle_app:app@127.0.0.1:55432/cycle_d_source'
DESTINATION_APP_URL='postgresql://cycle_app:app@127.0.0.1:55433/cycle_d_destination'
SOURCE_ROOT_URL='postgresql://postgres@127.0.0.1:55432/postgres'
DESTINATION_ROOT_URL='postgresql://postgres@127.0.0.1:55433/postgres'

for root_url in "$SOURCE_ROOT_URL" "$DESTINATION_ROOT_URL"; do
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_owner login password 'cycle';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_other login password 'other';"
  psql "$root_url" -v ON_ERROR_STOP=1 -c "create role cycle_app login password 'app';"
done
psql "$SOURCE_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ROOT_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create type public.stock_marker as (label text, rank integer);
alter type public.stock_marker owner to cycle_owner;
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null,
  marker public.stock_marker not null
);
insert into public.products values
  (1,'SOURCE-SKU-1',7,row('safe',1)::public.stock_marker),
  (2,'SOURCE-SKU-2',11,row('source',2)::public.stock_marker);
grant usage on schema public to cycle_other, cycle_app;
grant usage on type public.stock_marker to cycle_app;
grant select on public.products to cycle_app;
SQL

psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 <<'SQL'
create type public.stock_marker as (label text, rank integer);
alter type public.stock_marker owner to cycle_other;
create table public.products (
  id bigint primary key,
  sku text not null,
  quantity integer not null,
  marker public.stock_marker not null
);
insert into public.products values
  (1,'SOURCE-SKU-1',7,row('safe',1)::public.stock_marker);
grant usage on schema public to cycle_other, cycle_app;
grant usage on type public.stock_marker to cycle_app;
grant select on public.products to cycle_app;
SQL

owner_of_type() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(t.typowner) from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='stock_marker' and t.typtype='c';"
}
attribute_names() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F ',' -c "select string_agg(a.attname, ',' order by a.attnum) from pg_type t join pg_namespace n on n.oid=t.typnamespace join pg_class c on c.oid=t.typrelid join pg_attribute a on a.attrelid=c.oid where n.nspname='public' and t.typname='stock_marker' and t.typtype='c' and a.attnum>0 and not a.attisdropped;"
}
rename_label_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "alter type public.stock_marker rename attribute label to hijacked_label;"
}
app_probe() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity,(marker).label,(marker).rank from public.products where id=1;"
}

source_owner_before="$(owner_of_type "$SOURCE_ADMIN_URL")"
destination_owner_before="$(owner_of_type "$DESTINATION_ADMIN_URL")"
source_attrs_before="$(attribute_names "$SOURCE_ADMIN_URL")"
destination_attrs_before="$(attribute_names "$DESTINATION_ADMIN_URL")"
source_app_before="$(app_probe "$SOURCE_APP_URL")"
destination_app_before="$(app_probe "$DESTINATION_APP_URL")"

set +e
source_rename_output="$(rename_label_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_rename_exit=$?
destination_rename_output="$(rename_label_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_exit=$?
set -e

destination_attrs_mutated="$(attribute_names "$DESTINATION_ADMIN_URL")"
set +e
destination_app_mutated_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_mutated_exit=$?
set -e

printf 'BEFORE\nsource composite type owner=%s\ndestination composite type owner=%s\n' "$source_owner_before" "$destination_owner_before"
printf 'source attributes=%s\ndestination attributes=%s\n' "$source_attrs_before" "$destination_attrs_before"
printf 'source app row=%s\ndestination app row=%s\n' "$source_app_before" "$destination_app_before"
printf 'source cycle_other rename exit=%s\nsource cycle_other output=%s\n' "$source_rename_exit" "$source_rename_output"
printf 'destination cycle_other rename exit=%s\ndestination cycle_other output=%s\n' "$destination_rename_exit" "$destination_rename_output"
printf 'destination attributes after owner probe=%s\ndestination app probe after owner mutation exit=%s\ndestination app probe output=%s\n' "$destination_attrs_mutated" "$destination_app_mutated_exit" "$destination_app_mutated_output"

if [[ "$source_owner_before" != cycle_owner || "$destination_owner_before" != cycle_other || "$source_attrs_before" != 'label,rank' || "$destination_attrs_before" != 'label,rank' || "$source_app_before" != '1|SOURCE-SKU-1|7|safe|1' || "$destination_app_before" != '1|SOURCE-SKU-1|7|safe|1' || "$source_rename_exit" -eq 0 || "$destination_rename_exit" -ne 0 || "$destination_attrs_mutated" != 'hijacked_label,rank' || "$destination_app_mutated_exit" -eq 0 ]]; then
  echo 'Fixture did not establish isolated composite-type ownership drift.' >&2
  exit 2
fi

# Restore the disposable destination definition before the production sync while preserving ownership drift.
psql "$DESTINATION_OTHER_URL" -v ON_ERROR_STOP=1 -c "alter type public.stock_marker rename attribute hijacked_label to label;"
restored_attrs="$(attribute_names "$DESTINATION_ADMIN_URL")"
restored_app="$(app_probe "$DESTINATION_APP_URL")"
if [[ "$restored_attrs" != 'label,rank' || "$restored_app" != '1|SOURCE-SKU-1|7|safe|1' ]]; then
  echo 'Fixture restoration failed before production synchronization.' >&2
  exit 2
fi

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_COMPOSITE_TYPE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'composite.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*composite' <<<"$runtime_output"; then
    echo 'NEON_COMPOSITE_TYPE_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_COMPOSITE_TYPE_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_owner_after="$(owner_of_type "$DESTINATION_ADMIN_URL")"
destination_attrs_before_final="$(attribute_names "$DESTINATION_ADMIN_URL")"
destination_row_2="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity,(marker).label,(marker).rank from public.products where id=2;")"

set +e
destination_rename_after_output="$(rename_label_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_rename_after_exit=$?
set -e
destination_attrs_after_final="$(attribute_names "$DESTINATION_ADMIN_URL")"
set +e
destination_app_after_output="$(app_probe "$DESTINATION_APP_URL" 2>&1)"; destination_app_after_exit=$?
set -e

printf 'AFTER\ndestination composite type owner=%s\ndestination attributes before final owner probe=%s\nappended source row=%s\n' "$destination_owner_after" "$destination_attrs_before_final" "$destination_row_2"
printf 'destination cycle_other rename exit=%s\ndestination cycle_other output=%s\n' "$destination_rename_after_exit" "$destination_rename_after_output"
printf 'destination attributes after final owner probe=%s\ndestination cycle_app original-field probe exit=%s\ndestination cycle_app output=%s\nNEON_COMPOSITE_TYPE_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_attrs_after_final" "$destination_app_after_exit" "$destination_app_after_output" "$sync_exit"

if [[ "$destination_owner_after" == cycle_owner && "$destination_attrs_before_final" == 'label,rank' && "$destination_row_2" == '2|SOURCE-SKU-2|11|source|2' && "$destination_rename_after_exit" -ne 0 && "$destination_attrs_after_final" == 'label,rank' && "$destination_app_after_exit" -eq 0 ]]; then
  echo 'NEON_COMPOSITE_TYPE_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_COMPOSITE_TYPE_OWNER_DRIFT_DETECTED=false'
echo 'Destination retained composite-type owner authority that source assigns to a different role.' >&2
exit 1

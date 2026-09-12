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

create_family_and_class_sql() {
  cat <<'SQL'
create operator family public.retail_int4_family using btree;
create operator class public.retail_int4_ops
for type integer using btree family public.retail_int4_family as
  operator 1 pg_catalog.<(integer,integer),
  operator 2 pg_catalog.<=(integer,integer),
  operator 3 pg_catalog.=(integer,integer),
  operator 4 pg_catalog.>=(integer,integer),
  operator 5 pg_catalog.>(integer,integer),
  function 1 pg_catalog.btint4cmp(integer,integer);
SQL
}

setup_source() {
  {
    create_family_and_class_sql
    cat <<'SQL'
alter operator family public.retail_int4_family using btree owner to cycle_owner;
alter operator class public.retail_int4_ops using btree owner to cycle_owner;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.products
select g, 'BASE-SKU-' || g::text, g % 100 from generate_series(1,2000) g;
create index products_quantity_retail_idx on public.products using btree(quantity public.retail_int4_ops);
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_app;
SQL
  } | psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1
}

setup_destination() {
  {
    create_family_and_class_sql
    cat <<'SQL'
alter operator family public.retail_int4_family using btree owner to cycle_other;
alter operator class public.retail_int4_ops using btree owner to cycle_owner;
create table public.products(id bigint primary key, sku text not null, quantity integer not null);
insert into public.products
select g, 'BASE-SKU-' || g::text, g % 100 from generate_series(1,2000) g;
create index products_quantity_retail_idx on public.products using btree(quantity public.retail_int4_ops);
grant usage on schema public to cycle_other, cycle_app;
grant select on public.products to cycle_app;
SQL
  } | psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1
}

setup_source
setup_destination

operator_family_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(f.opfowner) from pg_opfamily f join pg_namespace n on n.oid=f.opfnamespace where n.nspname='public' and f.opfname='retail_int4_family' and f.opfmethod=(select oid from pg_am where amname='btree');"
}
operator_class_owner() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select pg_get_userbyid(c.opcowner) from pg_opclass c join pg_namespace n on n.oid=c.opcnamespace where n.nspname='public' and c.opcname='retail_int4_ops' and c.opcmethod=(select oid from pg_am where amname='btree');"
}
family_present() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select case when exists(select 1 from pg_opfamily f join pg_namespace n on n.oid=f.opfnamespace where n.nspname='public' and f.opfname='retail_int4_family' and f.opfmethod=(select oid from pg_am where amname='btree')) then 'true' else 'false' end;"
}
class_present() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select case when exists(select 1 from pg_opclass c join pg_namespace n on n.oid=c.opcnamespace where n.nspname='public' and c.opcname='retail_int4_ops' and c.opcmethod=(select oid from pg_am where amname='btree')) then 'true' else 'false' end;"
}
index_present() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select case when to_regclass('public.products_quantity_retail_idx') is null then 'false' else 'true' end;"
}
app_plan() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "set enable_seqscan=off; explain (costs off) select id,sku,quantity from public.products where quantity=7;"
}
app_count() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc "select count(*) from public.products where quantity=7;"
}
drop_family_as_other() {
  psql "$1" -v ON_ERROR_STOP=1 -c "drop operator family public.retail_int4_family using btree cascade;"
}
restore_destination_family() {
  {
    create_family_and_class_sql
    cat <<'SQL'
alter operator family public.retail_int4_family using btree owner to cycle_other;
alter operator class public.retail_int4_ops using btree owner to cycle_owner;
create index products_quantity_retail_idx on public.products using btree(quantity public.retail_int4_ops);
SQL
  } | psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1
}

source_family_owner_before="$(operator_family_owner "$SOURCE_ADMIN_URL")"
destination_family_owner_before="$(operator_family_owner "$DESTINATION_ADMIN_URL")"
source_class_owner_before="$(operator_class_owner "$SOURCE_ADMIN_URL")"
destination_class_owner_before="$(operator_class_owner "$DESTINATION_ADMIN_URL")"
source_index_before="$(index_present "$SOURCE_ADMIN_URL")"
destination_index_before="$(index_present "$DESTINATION_ADMIN_URL")"
source_count_before="$(app_count "$SOURCE_APP_URL")"
destination_count_before="$(app_count "$DESTINATION_APP_URL")"
source_plan_before="$(app_plan "$SOURCE_APP_URL")"
destination_plan_before="$(app_plan "$DESTINATION_APP_URL")"

set +e
source_drop_output="$(drop_family_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_exit=$?
destination_drop_output="$(drop_family_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_exit=$?
destination_plan_after_drop="$(app_plan "$DESTINATION_APP_URL" 2>&1)"; destination_plan_after_drop_exit=$?
set -e

destination_family_after_drop="$(family_present "$DESTINATION_ADMIN_URL")"
destination_class_after_drop="$(class_present "$DESTINATION_ADMIN_URL")"
destination_index_after_drop="$(index_present "$DESTINATION_ADMIN_URL")"
destination_count_after_drop="$(app_count "$DESTINATION_APP_URL")"

printf 'BEFORE\nsource operator family owner=%s\ndestination operator family owner=%s\n' "$source_family_owner_before" "$destination_family_owner_before"
printf 'source operator class owner=%s\ndestination operator class owner=%s\n' "$source_class_owner_before" "$destination_class_owner_before"
printf 'source index present=%s\ndestination index present=%s\n' "$source_index_before" "$destination_index_before"
printf 'source app count=%s\ndestination app count=%s\n' "$source_count_before" "$destination_count_before"
printf 'source plan=%s\ndestination plan=%s\n' "$source_plan_before" "$destination_plan_before"
printf 'source cycle_other family drop exit=%s\nsource cycle_other output=%s\n' "$source_drop_exit" "$source_drop_output"
printf 'destination cycle_other family drop exit=%s\ndestination cycle_other output=%s\n' "$destination_drop_exit" "$destination_drop_output"
printf 'destination family after owner drop=%s\ndestination class after owner drop=%s\ndestination index after owner drop=%s\ndestination app count after owner drop=%s\ndestination plan after owner drop exit=%s\ndestination plan after owner drop=%s\n' "$destination_family_after_drop" "$destination_class_after_drop" "$destination_index_after_drop" "$destination_count_after_drop" "$destination_plan_after_drop_exit" "$destination_plan_after_drop"

if [[ "$source_family_owner_before" != cycle_owner || "$destination_family_owner_before" != cycle_other || "$source_class_owner_before" != cycle_owner || "$destination_class_owner_before" != cycle_owner || "$source_index_before" != true || "$destination_index_before" != true || "$source_count_before" != 20 || "$destination_count_before" != 20 || "$source_drop_exit" -eq 0 || "$destination_drop_exit" -ne 0 || "$destination_family_after_drop" != false || "$destination_class_after_drop" != false || "$destination_index_after_drop" != false || "$destination_count_after_drop" != 20 ]]; then
  echo 'Fixture did not establish isolated operator-family ownership drift.' >&2
  exit 2
fi
if ! grep -Eq 'Index Scan|Index Only Scan|Bitmap Index Scan' <<<"$source_plan_before" || ! grep -Eq 'Index Scan|Index Only Scan|Bitmap Index Scan' <<<"$destination_plan_before"; then
  echo 'Baseline application plan did not use the custom operator-family index.' >&2
  exit 2
fi
if grep -Eq 'products_quantity_retail_idx' <<<"$destination_plan_after_drop"; then
  echo 'Destination family-owner mutation did not remove the dependent application index.' >&2
  exit 2
fi

restore_destination_family
if [[ "$(operator_family_owner "$DESTINATION_ADMIN_URL")" != cycle_other || "$(operator_class_owner "$DESTINATION_ADMIN_URL")" != cycle_owner || "$(index_present "$DESTINATION_ADMIN_URL")" != true ]]; then
  echo 'Fixture restoration failed before production synchronization.' >&2
  exit 2
fi

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c "insert into public.products values (2001,'SOURCE-SKU-2001',11);" >/dev/null

set +e
runtime_output="$(SOURCE_DATABASE_URL="$SOURCE_ADMIN_URL" DESTINATION_DATABASE_URL="$DESTINATION_ADMIN_URL" bash scripts/neon-sync/append-sync.sh 2>&1)"; sync_exit=$?
set -e
printf '%s\n' "$runtime_output"

if [[ "$sync_exit" -ne 0 ]]; then
  printf 'NEON_OPERATOR_FAMILY_OWNER_DRIFT_SYNC_EXIT=%s\n' "$sync_exit"
  if grep -Eqi 'operator family.*(owner|ownership).*(incompatib|drift|mismatch)|(owner|ownership).*operator family' <<<"$runtime_output"; then
    echo 'NEON_OPERATOR_FAMILY_OWNER_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_OPERATOR_FAMILY_OWNER_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

destination_family_owner_after="$(operator_family_owner "$DESTINATION_ADMIN_URL")"
destination_class_owner_after="$(operator_class_owner "$DESTINATION_ADMIN_URL")"
destination_row_2001="$(psql "$DESTINATION_APP_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=2001;")"
destination_index_before_final_drop="$(index_present "$DESTINATION_ADMIN_URL")"
destination_count_before_final_drop="$(app_count "$DESTINATION_APP_URL")"
destination_plan_before_final_drop="$(app_plan "$DESTINATION_APP_URL")"

set +e
source_drop_after_output="$(drop_family_as_other "$SOURCE_OTHER_URL" 2>&1)"; source_drop_after_exit=$?
destination_drop_after_output="$(drop_family_as_other "$DESTINATION_OTHER_URL" 2>&1)"; destination_drop_after_exit=$?
set -e

destination_family_after_final_drop="$(family_present "$DESTINATION_ADMIN_URL")"
destination_class_after_final_drop="$(class_present "$DESTINATION_ADMIN_URL")"
destination_index_after_final_drop="$(index_present "$DESTINATION_ADMIN_URL")"
destination_count_after_final_drop="$(app_count "$DESTINATION_APP_URL")"
destination_plan_after_final_drop="$(app_plan "$DESTINATION_APP_URL")"

printf 'AFTER\ndestination operator family owner=%s\ndestination operator class owner=%s\nappended source row=%s\n' "$destination_family_owner_after" "$destination_class_owner_after" "$destination_row_2001"
printf 'destination index before final owner drop=%s\ndestination app count before final owner drop=%s\ndestination plan before final owner drop=%s\n' "$destination_index_before_final_drop" "$destination_count_before_final_drop" "$destination_plan_before_final_drop"
printf 'source cycle_other final family drop exit=%s\nsource cycle_other final output=%s\n' "$source_drop_after_exit" "$source_drop_after_output"
printf 'destination cycle_other final family drop exit=%s\ndestination cycle_other final output=%s\n' "$destination_drop_after_exit" "$destination_drop_after_output"
printf 'destination family after final owner drop=%s\ndestination class after final owner drop=%s\ndestination index after final owner drop=%s\ndestination app count after final owner drop=%s\ndestination plan after final owner drop=%s\nNEON_OPERATOR_FAMILY_OWNER_DRIFT_SYNC_EXIT=%s\n' "$destination_family_after_final_drop" "$destination_class_after_final_drop" "$destination_index_after_final_drop" "$destination_count_after_final_drop" "$destination_plan_after_final_drop" "$sync_exit"

if [[ "$destination_family_owner_after" == cycle_owner && "$destination_class_owner_after" == cycle_owner && "$destination_row_2001" == '2001|SOURCE-SKU-2001|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -ne 0 && "$destination_index_before_final_drop" == true ]]; then
  echo 'NEON_OPERATOR_FAMILY_OWNER_DRIFT_DETECTED=true'
  exit 0
fi

if [[ "$destination_family_owner_after" == cycle_other && "$destination_class_owner_after" == cycle_owner && "$destination_row_2001" == '2001|SOURCE-SKU-2001|11' && "$source_drop_after_exit" -ne 0 && "$destination_drop_after_exit" -eq 0 && "$destination_family_after_final_drop" == false && "$destination_class_after_final_drop" == false && "$destination_index_before_final_drop" == true && "$destination_index_after_final_drop" == false && "$destination_count_before_final_drop" == 20 && "$destination_count_after_final_drop" == 20 ]] && grep -Eq 'products_quantity_retail_idx' <<<"$destination_plan_before_final_drop" && ! grep -Eq 'products_quantity_retail_idx' <<<"$destination_plan_after_final_drop"; then
  echo 'NEON_OPERATOR_FAMILY_OWNER_DRIFT_DETECTED=false'
  echo 'NEON_OPERATOR_FAMILY_OWNER_DRIFT_APPLICATION_EFFECT_VERIFIED=true'
  echo 'Destination retained operator-family owner authority that source assigns to a different role; owner-only CASCADE drop removed the operator class and application index and changed the real query plan.' >&2
  exit 1
fi

echo 'Post-sync operator-family ownership scenario produced an unexpected runtime state.' >&2
exit 2

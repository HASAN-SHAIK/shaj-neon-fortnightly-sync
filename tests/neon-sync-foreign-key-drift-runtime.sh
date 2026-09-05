#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/lib/postgresql/18/bin:$PATH"

SOURCE_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55432/postgres'
DESTINATION_ADMIN_URL='postgresql://postgres:postgres@127.0.0.1:55433/postgres'
SOURCE_URL='postgresql://postgres:postgres@127.0.0.1:55432/cycle_d_source'
DESTINATION_URL='postgresql://postgres:postgres@127.0.0.1:55433/cycle_d_destination'

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'
psql "$DESTINATION_ADMIN_URL" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'

psql "$SOURCE_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.categories (
  id bigint primary key,
  name text not null
);
create table public.products (
  id bigint primary key,
  sku text not null,
  category_id bigint not null,
  quantity integer not null,
  constraint products_category_fk foreign key (category_id) references public.categories(id)
);
insert into public.categories (id, name) values
  (10, 'SOURCE-CATEGORY-10'),
  (20, 'SOURCE-CATEGORY-20');
insert into public.products (id, sku, category_id, quantity) values
  (1, 'SOURCE-SKU-1', 10, 7),
  (2, 'SOURCE-SKU-2', 20, 11);
SQL

psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 <<'SQL'
create table public.categories (
  id bigint primary key,
  name text not null
);
create table public.products (
  id bigint primary key,
  sku text not null,
  category_id bigint not null,
  quantity integer not null
);
insert into public.categories (id, name) values
  (10, 'SOURCE-CATEGORY-10');
insert into public.products (id, sku, category_id, quantity) values
  (1, 'SOURCE-SKU-1', 10, 7);
SQL

source_fk_before="$(psql "$SOURCE_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='f' and conname='products_category_fk';")"
destination_fk_before="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='f' and conname='products_category_fk';")"

set +e
runtime_output="$(
  SOURCE_DATABASE_URL="$SOURCE_URL" \
  DESTINATION_DATABASE_URL="$DESTINATION_URL" \
  bash scripts/neon-sync/append-sync.sh 2>&1
)"
sync_exit=$?
set -e

printf '%s\n' "$runtime_output"

destination_fk_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_constraint where conrelid='public.products'::regclass and contype='f' and conname='products_category_fk';")"
destination_fk_def_after="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -Atc "select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.products'::regclass and contype='f' and conname='products_category_fk';")"
destination_category_20="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, name from public.categories where id=20;")"
destination_source_row_2="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "select id, sku, category_id, quantity from public.products where id=2;")"

set +e
probe_output="$(psql "$DESTINATION_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "insert into public.products (id, sku, category_id, quantity) values (900, 'INVALID-FK-SKU-900', 999999, 29); select id, sku, category_id, quantity from public.products where id=900;" 2>&1)"
probe_exit=$?
set -e

printf 'NEON_FK_SYNC_EXIT=%s\n' "$sync_exit"
printf 'NEON_FK_SOURCE_BEFORE=%s\n' "$source_fk_before"
printf 'NEON_FK_DESTINATION_BEFORE=%s\n' "$destination_fk_before"
printf 'NEON_FK_DESTINATION_AFTER=%s\n' "$destination_fk_after"
printf 'NEON_FK_CONSTRAINT_DEF_AFTER=%s\n' "$destination_fk_def_after"
printf 'NEON_FK_APPENDED_CATEGORY=%s\n' "$destination_category_20"
printf 'NEON_FK_APPENDED_SOURCE_ROW=%s\n' "$destination_source_row_2"
printf 'NEON_FK_PROBE_EXIT=%s\n' "$probe_exit"
printf 'NEON_FK_PROBE_OUTPUT=%s\n' "$probe_output"

test "$source_fk_before" = '1'
test "$destination_fk_before" = '0'

if [[ "$sync_exit" -ne 0 ]]; then
  if grep -Eiq 'foreign key|products_category_fk' <<<"$runtime_output"; then
    echo 'NEON_FOREIGN_KEY_DRIFT_DETECTED=true'
    exit 0
  fi
  echo 'NEON_FOREIGN_KEY_DRIFT_DETECTED=unverified' >&2
  echo 'Production failed for a reason not demonstrated to be the foreign-key incompatibility.' >&2
  exit 1
fi

if [[ "$destination_fk_after" == '1' \
      && "$destination_fk_def_after" == *'FOREIGN KEY (category_id) REFERENCES categories(id)'* \
      && "$destination_category_20" == '20|SOURCE-CATEGORY-20' \
      && "$destination_source_row_2" == '2|SOURCE-SKU-2|20|11' \
      && "$probe_exit" -ne 0 \
      && "$probe_output" == *'products_category_fk'* \
      && "$runtime_output" == *'Append sync and verification completed successfully for default.'* \
      && "$runtime_output" == *'All configured Neon database syncs completed successfully.'* ]]; then
  echo 'NEON_FOREIGN_KEY_DRIFT_DETECTED=true'
  exit 0
fi

echo 'NEON_FOREIGN_KEY_DRIFT_DETECTED=false' >&2
echo 'Production reported successful synchronization without proving source foreign-key semantics on the writable destination.' >&2
exit 1

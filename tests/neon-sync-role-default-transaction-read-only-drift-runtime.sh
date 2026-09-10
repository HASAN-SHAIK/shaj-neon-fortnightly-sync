#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set default_transaction_read_only = off;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set default_transaction_read_only = on;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select, insert on public.products to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100
from generate_series(1,20000) g;
analyze public.products;
SQL
done

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'default_transaction_read_only=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c 'show default_transaction_read_only;'; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
app_insert() {
  local url="$1" id="$2" sku="$3" qty="$4"
  set +e
  APP_INSERT_OUTPUT="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "insert into public.products(id,sku,quantity) values ($id,'$sku',$qty);" 2>&1)"
  APP_INSERT_RC=$?
  set -e
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"

app_insert "$SRC_APP" 20001 'SOURCE-SKU-20001' 11
src_write_rc="$APP_INSERT_RC"; src_write_output="$APP_INSERT_OUTPUT"
app_insert "$DST_APP" 30001 'DEST-SKU-30001' 12
dst_write_rc="$APP_INSERT_RC"; dst_write_output="$APP_INSERT_OUTPUT"

printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource application write rc=%s output=%s\ndestination application write rc=%s output=%s\n' \
  "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_write_rc" "$src_write_output" "$dst_write_rc" "$dst_write_output"

[[ "${src_catalog,,}" == 'default_transaction_read_only=off' && "${dst_catalog,,}" == 'default_transaction_read_only=on' ]] || { echo 'Catalog fixture did not persist both default_transaction_read_only settings.' >&2; exit 2; }
[[ "${src_effective,,}" == 'off' && "${dst_effective,,}" == 'on' ]] || { echo 'Application principals did not inherit the intended read-only settings.' >&2; exit 2; }
[[ "$src_row" == '15000|SOURCE-SKU-15000|0' && "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || { echo 'Ordinary baseline application state differs.' >&2; exit 2; }
[[ "$src_write_rc" -eq 0 ]] || { echo 'Source application write unexpectedly failed.' >&2; exit 2; }
[[ "$dst_write_rc" -ne 0 ]] || { echo 'Destination application write unexpectedly succeeded despite read-only policy.' >&2; exit 2; }
grep -Eqi 'read-only transaction|read only transaction' <<<"$dst_write_output" || { echo 'Destination failure was not the expected read-only transaction error.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_DEFAULT_TRANSACTION_READ_ONLY_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'default_transaction_read_only|pg_db_role_setting|read.only|role setting' <<<"$out"; then
    echo 'NEON_ROLE_DEFAULT_TRANSACTION_READ_ONLY_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_DEFAULT_TRANSACTION_READ_ONLY_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

# The admin synchronization path may write even though the real application role is read-only.
dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"

app_insert "$SRC_APP" 20002 'SOURCE-SKU-20002' 13
src_write_after_rc="$APP_INSERT_RC"; src_write_after_output="$APP_INSERT_OUTPUT"
app_insert "$DST_APP" 30002 'DEST-SKU-30002' 14
dst_write_after_rc="$APP_INSERT_RC"; dst_write_after_output="$APP_INSERT_OUTPUT"
dst_failed_row_count="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -c 'select count(*) from public.products where id in (30001,30002);')"

printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource application write rc=%s output=%s\ndestination application write rc=%s output=%s\ndestination failed-write row count=%s\nNEON_ROLE_DEFAULT_TRANSACTION_READ_ONLY_DRIFT_SYNC_EXIT=%s\n' \
  "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$src_write_after_rc" "$src_write_after_output" "$dst_write_after_rc" "$dst_write_after_output" "$dst_failed_row_count" "$rc"

[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate source application row did not synchronize.' >&2; exit 2; }
[[ "${src_effective_after,,}" == 'off' && "${dst_effective_after,,}" == 'on' ]] || { echo 'Read-only application boundary did not persist after sync.' >&2; exit 2; }
[[ "$src_write_after_rc" -eq 0 ]] || { echo 'Source application write unexpectedly failed after sync.' >&2; exit 2; }
[[ "$dst_write_after_rc" -ne 0 ]] || { echo 'Destination application write unexpectedly succeeded after sync.' >&2; exit 2; }
grep -Eqi 'read-only transaction|read only transaction' <<<"$dst_write_after_output" || { echo 'Destination post-sync failure was not the expected read-only transaction error.' >&2; exit 2; }
[[ "$dst_failed_row_count" == '0' ]] || { echo 'A destination application write unexpectedly persisted.' >&2; exit 2; }

echo 'NEON_ROLE_DEFAULT_TRANSACTION_READ_ONLY_DRIFT_DETECTED=false'
exit 1

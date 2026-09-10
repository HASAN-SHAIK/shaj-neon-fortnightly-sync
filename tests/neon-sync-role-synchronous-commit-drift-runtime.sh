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
alter role cycle_app set synchronous_commit = on;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set synchronous_commit = off;
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
SQL
done

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'synchronous_commit=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c 'show synchronous_commit;'; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
app_insert() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -c "insert into public.products(id,sku,quantity) values ($2,'$3',$4);"
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"

printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row"

[[ "${src_catalog,,}" == 'synchronous_commit=on' && "${dst_catalog,,}" == 'synchronous_commit=off' ]] || { echo 'Catalog fixture did not persist both synchronous_commit settings.' >&2; exit 2; }
[[ "${src_effective,,}" == 'on' && "${dst_effective,,}" == 'off' ]] || { echo 'Application principals did not inherit intended synchronous_commit settings.' >&2; exit 2; }
[[ "$src_row" == '15000|SOURCE-SKU-15000|0' && "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || { echo 'Baseline application state differs.' >&2; exit 2; }

app_insert "$SRC_APP" 20001 'SOURCE-SKU-20001' 11 >/dev/null
src_appended="$(psql "$SRC_APP" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
[[ "$src_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Source application commit did not become visible.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_SYNCHRONOUS_COMMIT_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'synchronous_commit|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_SYNCHRONOUS_COMMIT_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_SYNCHRONOUS_COMMIT_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
app_insert "$DST_APP" 30001 'DEST-SKU-30001' 12 >/dev/null
dst_direct="$(psql "$DST_APP" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=30001;')"

printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\ndestination direct app commit visible=%s\nNEON_ROLE_SYNCHRONOUS_COMMIT_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$dst_direct" "$rc"

[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate source row did not synchronize.' >&2; exit 2; }
[[ "${src_effective_after,,}" == 'on' && "${dst_effective_after,,}" == 'off' ]] || { echo 'synchronous_commit boundary did not persist after sync.' >&2; exit 2; }
[[ "$dst_direct" == '30001|DEST-SKU-30001|12' ]] || { echo 'Destination application commit was not visible after success.' >&2; exit 2; }

echo 'NEON_ROLE_SYNCHRONOUS_COMMIT_DRIFT_DETECTED=false'
echo 'NEON_ROLE_SYNCHRONOUS_COMMIT_CRASH_DURABILITY_VERIFIED=false'
exit 1

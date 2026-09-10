#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SETTING='search_path'

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set search_path = app, public;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set search_path = public, app;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create schema app;
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.inventory_probe (id integer primary key, origin text not null, quantity integer not null);
create table app.inventory_probe (id integer primary key, origin text not null, quantity integer not null);
grant usage on schema public, app to cycle_app;
grant select on public.products, public.inventory_probe, app.inventory_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.inventory_probe values (1,'public',99);
insert into app.inventory_probe values (1,'app',11);
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like '${SETTING}=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "show ${SETTING};"; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
unqualified_probe() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select current_schema(),origin,quantity from inventory_probe where id=1;'; }
qualified_digest() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c "select (select origin||':'||quantity from public.inventory_probe where id=1),(select origin||':'||quantity from app.inventory_probe where id=1);"
}

assert_runtime_boundary() {
  local src_setting="$1" dst_setting="$2" src_row="$3" dst_row="$4" src_probe="$5" dst_probe="$6" src_qualified="$7" dst_qualified="$8"
  [[ "$src_setting" == 'app, public' ]] || return 1
  [[ "$dst_setting" == 'public, app' ]] || return 1
  [[ "$src_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$src_probe" == 'app|app|11' ]] || return 1
  [[ "$dst_probe" == 'public|public|99' ]] || return 1
  [[ "$src_qualified" == 'public:99|app:11' ]] || return 1
  [[ "$dst_qualified" == 'public:99|app:11' ]] || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
src_probe="$(unqualified_probe "$SRC_APP")"; dst_probe="$(unqualified_probe "$DST_APP")"
src_qualified="$(qualified_digest "$SRC_APP")"; dst_qualified="$(qualified_digest "$DST_APP")"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource unqualified probe=%s\ndestination unqualified probe=%s\nsource qualified state=%s\ndestination qualified state=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe" "$src_qualified" "$dst_qualified"
[[ "${src_catalog,,}" == ${SETTING}=* && "${dst_catalog,,}" == ${SETTING}=* ]] || { echo 'Catalog fixture did not persist both role settings.' >&2; exit 2; }
assert_runtime_boundary "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe" "$src_qualified" "$dst_qualified" || { echo 'Fixture did not establish the required search-path application boundary.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_SEARCH_PATH_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'search_path|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_SEARCH_PATH_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_SEARCH_PATH_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"; dst_row_after="$(ordinary_row "$DST_APP")"
src_probe_after="$(unqualified_probe "$SRC_APP")"; dst_probe_after="$(unqualified_probe "$DST_APP")"
src_qualified_after="$(qualified_digest "$SRC_APP")"; dst_qualified_after="$(qualified_digest "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource unqualified probe=%s\ndestination unqualified probe=%s\nsource qualified state=%s\ndestination qualified state=%s\nNEON_ROLE_SEARCH_PATH_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$src_probe_after" "$dst_probe_after" "$src_qualified_after" "$dst_qualified_after" "$rc"
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_runtime_boundary "$src_effective_after" "$dst_effective_after" "$src_row_after" "$dst_row_after" "$src_probe_after" "$dst_probe_after" "$src_qualified_after" "$dst_qualified_after" || { echo 'Search-path application boundary did not persist after sync.' >&2; exit 2; }
echo 'NEON_ROLE_SEARCH_PATH_DRIFT_DETECTED=false'
exit 1

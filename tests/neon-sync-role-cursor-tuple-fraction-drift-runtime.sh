#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SETTING='cursor_tuple_fraction'

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set cursor_tuple_fraction = 0.0001;
alter role cycle_app set random_page_cost = 16;
alter role cycle_app set seq_page_cost = 1;
alter role cycle_app set max_parallel_workers_per_gather = 0;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set enable_indexonlyscan = off;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set cursor_tuple_fraction = 1.0;
alter role cycle_app set random_page_cost = 16;
alter role cycle_app set seq_page_cost = 1;
alter role cycle_app set max_parallel_workers_per_gather = 0;
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set enable_indexonlyscan = off;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.cursor_probe (id bigint primary key, sort_key integer not null, payload text not null);
create index cursor_probe_sort_key_idx on public.cursor_probe(sort_key);
alter table public.cursor_probe owner to cycle_app;
grant select on public.products to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.cursor_probe
select g, ((g * 7919) % 120000)::integer, repeat(md5(g::text),4) from generate_series(1,120000) g;
analyze public.cursor_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like '${SETTING}=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "show ${SETTING};"; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
cursor_plan() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) declare cycle_cursor no scroll cursor for select id,sort_key,payload from public.cursor_probe order by sort_key;"
}
cursor_fetch() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
BEGIN;
DECLARE cycle_cursor NO SCROLL CURSOR FOR SELECT id,sort_key,payload FROM public.cursor_probe ORDER BY sort_key;
FETCH FORWARD 10 FROM cycle_cursor;
CLOSE cycle_cursor;
COMMIT;
SQL
}

assert_runtime_boundary() {
  local src_setting="$1" dst_setting="$2" src_row="$3" dst_row="$4" src_plan="$5" dst_plan="$6" src_fetch="$7" dst_fetch="$8"
  [[ "$src_setting" == '0.0001' ]] || return 1
  [[ "$dst_setting" == '1' || "$dst_setting" == '1.0' ]] || return 1
  [[ "$src_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$src_fetch" == "$dst_fetch" ]] || return 1
  grep -Fq 'Index Scan using cursor_probe_sort_key_idx on cursor_probe' <<<"$src_plan" || return 1
  ! grep -Fq 'Sort' <<<"$src_plan" || return 1
  grep -Fq 'Sort' <<<"$dst_plan" || return 1
  grep -Fq 'Seq Scan on cursor_probe' <<<"$dst_plan" || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
src_plan="$(cursor_plan "$SRC_APP")"; dst_plan="$(cursor_plan "$DST_APP")"
src_fetch="$(cursor_fetch "$SRC_APP")"; dst_fetch="$(cursor_fetch "$DST_APP")"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource cursor plan=%s\ndestination cursor plan=%s\nsource cursor fetch=%s\ndestination cursor fetch=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$(tr '\n' ';' <<<"$src_plan")" "$(tr '\n' ';' <<<"$dst_plan")" "$(tr '\n' ';' <<<"$src_fetch")" "$(tr '\n' ';' <<<"$dst_fetch")"
[[ "${src_catalog,,}" == ${SETTING}=* && "${dst_catalog,,}" == ${SETTING}=* ]] || { echo 'Catalog fixture did not persist both role settings.' >&2; exit 2; }
assert_runtime_boundary "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_plan" "$dst_plan" "$src_fetch" "$dst_fetch" || { echo 'Fixture did not establish the required cursor-planning application boundary.' >&2; exit 2; }

set +e
out="$(EXCLUDED_TABLES='public.cursor_probe' SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_CURSOR_TUPLE_FRACTION_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'cursor_tuple_fraction|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_CURSOR_TUPLE_FRACTION_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_CURSOR_TUPLE_FRACTION_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"; dst_row_after="$(ordinary_row "$DST_APP")"
src_plan_after="$(cursor_plan "$SRC_APP")"; dst_plan_after="$(cursor_plan "$DST_APP")"
src_fetch_after="$(cursor_fetch "$SRC_APP")"; dst_fetch_after="$(cursor_fetch "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource cursor plan=%s\ndestination cursor plan=%s\nsource cursor fetch=%s\ndestination cursor fetch=%s\nNEON_ROLE_CURSOR_TUPLE_FRACTION_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$(tr '\n' ';' <<<"$src_plan_after")" "$(tr '\n' ';' <<<"$dst_plan_after")" "$(tr '\n' ';' <<<"$src_fetch_after")" "$(tr '\n' ';' <<<"$dst_fetch_after")" "$rc"
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_runtime_boundary "$src_effective_after" "$dst_effective_after" "$src_row_after" "$dst_row_after" "$src_plan_after" "$dst_plan_after" "$src_fetch_after" "$dst_fetch_after" || { echo 'Cursor-planning application boundary did not persist after sync.' >&2; exit 2; }
echo 'NEON_ROLE_CURSOR_TUPLE_FRACTION_DRIFT_DETECTED=false'
exit 1

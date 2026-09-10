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
alter role cycle_app set cpu_index_tuple_cost = 100;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set cpu_index_tuple_cost = 0.0001;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.cpu_index_tuple_cost_probe (
  id bigint primary key,
  bucket integer not null,
  payload text not null
);
create index cpu_index_tuple_cost_probe_bucket_idx on public.cpu_index_tuple_cost_probe(bucket);
grant usage on schema public to cycle_app;
grant select on public.products, public.cpu_index_tuple_cost_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.cpu_index_tuple_cost_probe
select g, g % 10, repeat(md5(g::text), 8)
from generate_series(1,200000) g;
analyze public.products;
analyze public.cpu_index_tuple_cost_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'cpu_index_tuple_cost=%';"
}

probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
show cpu_index_tuple_cost;
set seq_page_cost=1;
set random_page_cost=0.1;
set cpu_tuple_cost=0.01;
set max_parallel_workers_per_gather=0;
set enable_bitmapscan=off;
set enable_indexonlyscan=off;
explain (analyze, costs off, timing off, summary off)
select id,bucket,payload from public.cpu_index_tuple_cost_probe where bucket < 5;
select md5(string_agg(id::text || ':' || bucket::text || ':' || payload, ',' order by id))
from public.cpu_index_tuple_cost_probe where bucket < 5;
select id,sku,quantity from public.products where id=15000;
SQL
}

assert_common() {
  local v="$1"
  grep -Eq '^[0-9a-f]{32}$' <<<"$v" || return 1
  grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$v" || return 1
}
assert_source() {
  local v="$1"
  grep -Fxiq '100' <<<"$v" || return 1
  grep -Eq 'Seq Scan on cpu_index_tuple_cost_probe' <<<"$v" || return 1
  ! grep -Eq 'Index Scan using cpu_index_tuple_cost_probe_bucket_idx on cpu_index_tuple_cost_probe' <<<"$v" || return 1
  assert_common "$v"
}
assert_destination() {
  local v="$1"
  grep -Fxiq '0.0001' <<<"$v" || return 1
  grep -Eq 'Index Scan using cpu_index_tuple_cost_probe_bucket_idx on cpu_index_tuple_cost_probe' <<<"$v" || return 1
  ! grep -Eq 'Seq Scan on cpu_index_tuple_cost_probe' <<<"$v" || return 1
  assert_common "$v"
}
digest() { grep -E '^[0-9a-f]{32}$' <<<"$1" | tail -n1; }

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app cpu-index-tuple-cost probe=%s\ndestination app cpu-index-tuple-cost probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'cpu_index_tuple_cost=100' && "${dst_setting,,}" == 'cpu_index_tuple_cost=0.0001' ]] || { echo 'Fixture did not establish cpu_index_tuple_cost drift.' >&2; exit 2; }
assert_source "$src_probe" || { echo "Source did not choose sequential access under cpu_index_tuple_cost=100: $src_probe" >&2; exit 2; }
assert_destination "$dst_probe" || { echo "Destination did not choose indexed access under cpu_index_tuple_cost=0.0001: $dst_probe" >&2; exit 2; }
[[ "$(digest "$src_probe")" == "$(digest "$dst_probe")" ]] || { echo 'Probe results differ before sync.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_CPU_INDEX_TUPLE_COST_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'cpu_index_tuple_cost|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_CPU_INDEX_TUPLE_COST_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_CPU_INDEX_TUPLE_COST_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app cpu-index-tuple-cost probe=%s\ndestination app cpu-index-tuple-cost probe=%s\nNEON_ROLE_CPU_INDEX_TUPLE_COST_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'cpu_index_tuple_cost=0.0001' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_source "$src_after" || { echo 'Source cpu_index_tuple_cost behavior did not persist.' >&2; exit 2; }
assert_destination "$dst_after" || { echo 'Destination cpu_index_tuple_cost behavior did not persist.' >&2; exit 2; }
[[ "$(digest "$src_after")" == "$(digest "$dst_after")" ]] || { echo 'Probe results differ after sync.' >&2; exit 2; }
echo 'NEON_ROLE_CPU_INDEX_TUPLE_COST_DRIFT_DETECTED=false'
exit 1

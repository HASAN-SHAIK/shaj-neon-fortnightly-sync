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
alter role cycle_app set enable_parallel_hash = on;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_parallel_hash = off;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.parallel_hash_left (id bigint primary key, tenant_id integer not null, payload integer not null);
create table public.parallel_hash_right (id bigint primary key, category_id integer not null, payload integer not null);
grant usage on schema public to cycle_app;
grant select on public.products, public.parallel_hash_left, public.parallel_hash_right to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.parallel_hash_left
select g, g % 100, g % 17 from generate_series(1,300000) g;
insert into public.parallel_hash_right
select g, g % 50, g % 23 from generate_series(1,300000) g;
analyze public.products;
analyze public.parallel_hash_left;
analyze public.parallel_hash_right;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_parallel_hash=%';"
}

probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
show enable_parallel_hash;
set max_parallel_workers_per_gather=4;
set min_parallel_table_scan_size=0;
set min_parallel_index_scan_size=0;
set parallel_setup_cost=0;
set parallel_tuple_cost=0;
set enable_hashjoin=on;
set enable_mergejoin=off;
set enable_nestloop=off;
set enable_indexscan=off;
set enable_indexonlyscan=off;
set enable_bitmapscan=off;
explain (costs off)
select count(*)
from public.parallel_hash_left l
join public.parallel_hash_right r on r.id=l.id;
select count(*)
from public.parallel_hash_left l
join public.parallel_hash_right r on r.id=l.id;
select id,sku,quantity from public.products where id=15000;
SQL
}

assert_common() {
  local v="$1"
  grep -Fxq '300000' <<<"$v" || return 1
  grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$v" || return 1
  grep -q 'Gather' <<<"$v" || return 1
}
assert_source() {
  local v="$1"
  grep -Fxq 'on' <<<"$v" || return 1
  grep -q 'Parallel Hash Join' <<<"$v" || return 1
  grep -q 'Parallel Hash' <<<"$v" || return 1
  assert_common "$v"
}
assert_destination() {
  local v="$1"
  grep -Fxq 'off' <<<"$v" || return 1
  grep -q 'Hash Join' <<<"$v" || return 1
  ! grep -q 'Parallel Hash Join' <<<"$v" || return 1
  ! grep -Eq '^Parallel Hash$|^[[:space:]]*Parallel Hash$' <<<"$v" || return 1
  assert_common "$v"
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app parallel-hash probe=%s\ndestination app parallel-hash probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'enable_parallel_hash=on' && "${dst_setting,,}" == 'enable_parallel_hash=off' ]] || { echo 'Fixture did not establish parallel-hash drift.' >&2; exit 2; }
assert_source "$src_probe" || { echo "Source did not use Parallel Hash: $src_probe" >&2; exit 2; }
assert_destination "$dst_probe" || { echo "Destination did not use the required non-parallel hash strategy: $dst_probe" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_PARALLEL_HASH_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'enable_parallel_hash|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_ENABLE_PARALLEL_HASH_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_ENABLE_PARALLEL_HASH_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app parallel-hash probe=%s\ndestination app parallel-hash probe=%s\nNEON_ROLE_ENABLE_PARALLEL_HASH_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'enable_parallel_hash=off' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_source "$src_after" || { echo 'Source Parallel Hash behavior did not persist.' >&2; exit 2; }
assert_destination "$dst_after" || { echo 'Destination non-parallel Hash Join behavior did not persist.' >&2; exit 2; }
echo 'NEON_ROLE_ENABLE_PARALLEL_HASH_DRIFT_DETECTED=false'
exit 1

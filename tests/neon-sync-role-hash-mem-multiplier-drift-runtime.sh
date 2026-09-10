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
alter role cycle_app set work_mem = '4MB';
alter role cycle_app set hash_mem_multiplier = 16;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set work_mem = '4MB';
alter role cycle_app set hash_mem_multiplier = 1;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.hash_mem_probe (
  id bigint primary key,
  group_key bigint not null,
  payload text not null
);
grant usage on schema public to cycle_app;
grant select on public.products, public.hash_mem_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.hash_mem_probe
select g, g, md5(g::text) || md5((g * 17)::text)
from generate_series(1,200000) g;
analyze public.products;
analyze public.hash_mem_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_settings() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and (lower(cfg) like 'work_mem=%' or lower(cfg) like 'hash_mem_multiplier=%') order by lower(cfg);"
}

probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
show work_mem;
show hash_mem_multiplier;
set max_parallel_workers_per_gather=0;
set enable_sort=off;
explain (analyze, costs off, timing off, summary off)
select group_key, count(*) from public.hash_mem_probe group by group_key;
select md5(string_agg(group_key::text || ':' || n::text, ',' order by group_key))
from (select group_key, count(*) n from public.hash_mem_probe group by group_key) s;
select id,sku,quantity from public.products where id=15000;
SQL
}

assert_common() {
  local v="$1"
  grep -Fxiq '4MB' <<<"$v" || return 1
  grep -q '^HashAggregate' <<<"$v" || return 1
  grep -q 'Group Key: group_key' <<<"$v" || return 1
  grep -q 'Seq Scan on hash_mem_probe' <<<"$v" || return 1
  grep -Eq '^[0-9a-f]{32}$' <<<"$v" || return 1
  grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$v" || return 1
}
assert_source() {
  local v="$1"
  grep -Fxiq '16' <<<"$v" || return 1
  grep -Eq 'Batches: 1([[:space:]]|$)' <<<"$v" || return 1
  ! grep -q 'Disk Usage:' <<<"$v" || return 1
  assert_common "$v"
}
assert_destination() {
  local v="$1"
  grep -Fxiq '1' <<<"$v" || return 1
  grep -Eq 'Batches: ([2-9]|[1-9][0-9]+)([[:space:]]|$)' <<<"$v" || return 1
  grep -Eq 'Disk Usage: [1-9][0-9]*kB' <<<"$v" || return 1
  assert_common "$v"
}
digest() { grep -E '^[0-9a-f]{32}$' <<<"$1" | tail -n1; }

src_setting="$(role_settings "$SRC_ADMIN")"; dst_setting="$(role_settings "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role settings=%s\ndestination role settings=%s\nsource app hash-memory probe=%s\ndestination app hash-memory probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
grep -Fxiq 'hash_mem_multiplier=16' <<<"$src_setting" || { echo 'Source fixture did not establish hash_mem_multiplier=16.' >&2; exit 2; }
grep -Fxiq 'hash_mem_multiplier=1' <<<"$dst_setting" || { echo 'Destination fixture did not establish hash_mem_multiplier=1.' >&2; exit 2; }
grep -Fxiq 'work_mem=4MB' <<<"$src_setting" || { echo 'Source fixture did not hold work_mem at 4MB.' >&2; exit 2; }
grep -Fxiq 'work_mem=4MB' <<<"$dst_setting" || { echo 'Destination fixture did not hold work_mem at 4MB.' >&2; exit 2; }
assert_source "$src_probe" || { echo "Source did not keep HashAggregate in one batch under multiplier 16: $src_probe" >&2; exit 2; }
assert_destination "$dst_probe" || { echo "Destination did not spill HashAggregate under multiplier 1: $dst_probe" >&2; exit 2; }
[[ "$(digest "$src_probe")" == "$(digest "$dst_probe")" ]] || { echo 'Aggregate results differ before sync.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_HASH_MEM_MULTIPLIER_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'hash_mem_multiplier|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_HASH_MEM_MULTIPLIER_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_HASH_MEM_MULTIPLIER_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_settings "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role settings=%s\nappended source row=%s\nsource app hash-memory probe=%s\ndestination app hash-memory probe=%s\nNEON_ROLE_HASH_MEM_MULTIPLIER_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
grep -Fxiq 'hash_mem_multiplier=1' <<<"$dst_setting_after" || { echo 'Destination hash_mem_multiplier changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_source "$src_after" || { echo 'Source hash-memory behavior did not persist.' >&2; exit 2; }
assert_destination "$dst_after" || { echo 'Destination hash-memory behavior did not persist.' >&2; exit 2; }
[[ "$(digest "$src_after")" == "$(digest "$dst_after")" ]] || { echo 'Aggregate results differ after sync.' >&2; exit 2; }
echo 'NEON_ROLE_HASH_MEM_MULTIPLIER_DRIFT_DETECTED=false'
exit 1

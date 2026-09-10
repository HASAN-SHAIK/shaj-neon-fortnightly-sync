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
alter role cycle_app set enable_presorted_aggregate = on;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_presorted_aggregate = off;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.presorted_aggregate_probe (
  id bigint primary key,
  sort_key integer not null,
  payload integer not null
);
create index presorted_aggregate_probe_sort_idx on public.presorted_aggregate_probe(sort_key, id);
grant usage on schema public to cycle_app;
grant select on public.products, public.presorted_aggregate_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.presorted_aggregate_probe
select g, (300001-g)::integer, (g % 97)::integer from generate_series(1,300000) g;
analyze public.products;
analyze public.presorted_aggregate_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_presorted_aggregate=%';"
}

probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
show enable_presorted_aggregate;
set max_parallel_workers_per_gather=0;
set enable_incremental_sort=off;
set work_mem='64kB';
explain (costs off)
select array_agg(payload order by sort_key, id)
from public.presorted_aggregate_probe;
select md5(array_to_string(array_agg(payload order by sort_key, id), ','))
from public.presorted_aggregate_probe;
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
  grep -Fxq 'on' <<<"$v" || return 1
  grep -q 'Index Scan using presorted_aggregate_probe_sort_idx' <<<"$v" || return 1
  assert_common "$v"
}
assert_destination() {
  local v="$1"
  grep -Fxq 'off' <<<"$v" || return 1
  grep -q 'Seq Scan on presorted_aggregate_probe' <<<"$v" || return 1
  ! grep -q 'Index Scan using presorted_aggregate_probe_sort_idx' <<<"$v" || return 1
  assert_common "$v"
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app presorted-aggregate probe=%s\ndestination app presorted-aggregate probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'enable_presorted_aggregate=on' && "${dst_setting,,}" == 'enable_presorted_aggregate=off' ]] || { echo 'Fixture did not establish presorted-aggregate drift.' >&2; exit 2; }
assert_source "$src_probe" || { echo "Source did not consume presorted index input: $src_probe" >&2; exit 2; }
assert_destination "$dst_probe" || { echo "Destination did not use the required unsorted sequential input: $dst_probe" >&2; exit 2; }

src_digest="$(grep -E '^[0-9a-f]{32}$' <<<"$src_probe" | tail -1)"
dst_digest="$(grep -E '^[0-9a-f]{32}$' <<<"$dst_probe" | tail -1)"
[[ "$src_digest" == "$dst_digest" ]] || { echo 'Aggregate results differ before sync.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_PRESORTED_AGGREGATE_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'enable_presorted_aggregate|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_ENABLE_PRESORTED_AGGREGATE_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_ENABLE_PRESORTED_AGGREGATE_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app presorted-aggregate probe=%s\ndestination app presorted-aggregate probe=%s\nNEON_ROLE_ENABLE_PRESORTED_AGGREGATE_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'enable_presorted_aggregate=off' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_source "$src_after" || { echo 'Source presorted-aggregate behavior did not persist.' >&2; exit 2; }
assert_destination "$dst_after" || { echo 'Destination non-presorted aggregate behavior did not persist.' >&2; exit 2; }
src_digest_after="$(grep -E '^[0-9a-f]{32}$' <<<"$src_after" | tail -1)"
dst_digest_after="$(grep -E '^[0-9a-f]{32}$' <<<"$dst_after" | tail -1)"
[[ "$src_digest_after" == "$dst_digest_after" ]] || { echo 'Aggregate results differ after sync.' >&2; exit 2; }
echo 'NEON_ROLE_ENABLE_PRESORTED_AGGREGATE_DRIFT_DETECTED=false'
exit 1

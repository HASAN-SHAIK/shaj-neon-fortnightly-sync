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
alter role cycle_app set plan_cache_mode = 'force_custom_plan';
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set plan_cache_mode = 'force_generic_plan';
alter role cycle_app set enable_bitmapscan = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.plan_cache_probe (
  id bigint primary key,
  category text not null,
  payload text not null
);
create index plan_cache_probe_category_idx on public.plan_cache_probe(category);
grant usage on schema public to cycle_app;
grant select on public.products, public.plan_cache_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.plan_cache_probe
select g,
       case when g <= 100 then 'rare' else 'hot' end,
       repeat(md5(g::text), 8)
from generate_series(1,200000) g;
analyze public.products;
analyze public.plan_cache_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'plan_cache_mode=%';"
}

probe() {
  local url="$1"
  psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
show plan_cache_mode;
prepare cycle_plan(text) as
  select sum(length(payload)) from public.plan_cache_probe where category=$1;
explain (costs off) execute cycle_plan('rare');
execute cycle_plan('rare');
select id,sku,quantity from public.products where id=15000;
SQL
}

src_setting="$(role_setting "$SRC_ADMIN")"
dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"
dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app plan-cache probe=%s\ndestination app plan-cache probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"

[[ "${src_setting,,}" == 'plan_cache_mode=force_custom_plan' && "${dst_setting,,}" == 'plan_cache_mode=force_generic_plan' ]] || { echo 'Fixture did not establish plan_cache_mode drift.' >&2; exit 2; }
[[ "$src_probe" == force_custom_plan$'\n'*"Index Scan using plan_cache_probe_category_idx"*"category = 'rare'::text"*$'\n25600\n15000|SOURCE-SKU-15000|0' ]] || { echo "Source did not choose the expected selective custom plan: $src_probe" >&2; exit 2; }
[[ "$dst_probe" == force_generic_plan$'\n'*"Seq Scan on plan_cache_probe"*'category = $1'*$'\n25600\n15000|SOURCE-SKU-15000|0' ]] || { echo "Destination did not choose the expected generic plan: $dst_probe" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.plan_cache_probe' bash scripts/neon-sync/append-sync.sh 2>&1)"
rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_PLAN_CACHE_MODE_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'plan_cache_mode|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_PLAN_CACHE_MODE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_PLAN_CACHE_MODE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"
dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app plan-cache probe=%s\ndestination app plan-cache probe=%s\nNEON_ROLE_PLAN_CACHE_MODE_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"

[[ "${dst_setting_after,,}" == 'plan_cache_mode=force_generic_plan' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
[[ "$src_after" == force_custom_plan$'\n'*"Index Scan using plan_cache_probe_category_idx"*"category = 'rare'::text"*$'\n25600\n15000|SOURCE-SKU-15000|0' ]] || { echo 'Source custom-plan behavior did not persist.' >&2; exit 2; }
[[ "$dst_after" == force_generic_plan$'\n'*"Seq Scan on plan_cache_probe"*'category = $1'*$'\n25600\n15000|SOURCE-SKU-15000|0' ]] || { echo 'Destination generic-plan behavior did not persist.' >&2; exit 2; }
echo 'NEON_ROLE_PLAN_CACHE_MODE_DRIFT_DETECTED=false'
exit 1

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
alter role cycle_app set join_collapse_limit = 1;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set join_collapse_limit = 8;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;

create table public.join_a (id integer primary key, k integer not null, payload text not null);
create table public.join_b (id integer primary key, k integer not null, payload text not null);
create table public.join_c (k integer primary key, payload text not null);
insert into public.join_a select g, g % 10000, repeat('a',32) from generate_series(1,100000) g;
insert into public.join_b select g, g % 10000, repeat('b',32) from generate_series(1,100000) g;
insert into public.join_c select g, repeat('c',32) from generate_series(1,10) g;
analyze public.join_a; analyze public.join_b; analyze public.join_c;

grant usage on schema public to cycle_app;
grant select on public.products, public.join_a, public.join_b, public.join_c to cycle_app;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'join_collapse_limit=%';"
}
probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At <<'SQL'
show join_collapse_limit;
set max_parallel_workers_per_gather = 0;
set enable_nestloop = off;
set enable_mergejoin = off;
explain (costs off)
select count(*)
from (public.join_a a join public.join_b b on a.k=b.k)
join public.join_c c on b.k=c.k;
select count(*) from (public.join_a a join public.join_b b on a.k=b.k) join public.join_c c on b.k=c.k;
select id || '|' || sku || '|' || quantity from public.products where id=15000;
SQL
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app join probe=%s\ndestination app join probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'join_collapse_limit=1' && "${dst_setting,,}" == 'join_collapse_limit=8' ]] || { echo 'Fixture did not establish join_collapse_limit drift.' >&2; exit 2; }
grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$src_probe" || { echo 'Source ordinary application row missing.' >&2; exit 2; }
grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$dst_probe" || { echo 'Destination ordinary application row missing.' >&2; exit 2; }
src_count="$(tail -n 2 <<<"$src_probe" | head -n 1)"; dst_count="$(tail -n 2 <<<"$dst_probe" | head -n 1)"
[[ "$src_count" == "$dst_count" && "$src_count" =~ ^[0-9]+$ ]] || { echo "Join result mismatch: source=$src_count destination=$dst_count" >&2; exit 2; }
src_plan="$(sed -n '2,/^[0-9][0-9]*$/p' <<<"$src_probe" | sed '$d')"; dst_plan="$(sed -n '2,/^[0-9][0-9]*$/p' <<<"$dst_probe" | sed '$d')"
plan_diverged=false
if [[ "$src_plan" != "$dst_plan" ]]; then plan_diverged=true; fi

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.join_a,public.join_b,public.join_c' bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_JOIN_COLLAPSE_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'join_collapse_limit|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_JOIN_COLLAPSE_LIMIT_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_JOIN_COLLAPSE_LIMIT_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app join probe=%s\ndestination app join probe=%s\nNEON_ROLE_JOIN_COLLAPSE_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'join_collapse_limit=8' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
src_count_after="$(tail -n 2 <<<"$src_after" | head -n 1)"; dst_count_after="$(tail -n 2 <<<"$dst_after" | head -n 1)"
[[ "$src_count_after" == "$dst_count_after" && "$src_count_after" == "$src_count" ]] || { echo 'Join result changed unexpectedly after sync.' >&2; exit 2; }
echo 'NEON_ROLE_JOIN_COLLAPSE_LIMIT_DRIFT_DETECTED=false'
if [[ "$plan_diverged" == true ]]; then
  echo 'NEON_ROLE_JOIN_COLLAPSE_LIMIT_PLAN_DIVERGENCE=true'
  exit 1
fi
echo 'NEON_ROLE_JOIN_COLLAPSE_LIMIT_PLAN_DIVERGENCE=false'
exit 3

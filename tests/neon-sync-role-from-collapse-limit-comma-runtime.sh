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
alter role cycle_app set from_collapse_limit = 1;
alter role cycle_app set join_collapse_limit = 32;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set from_collapse_limit = 8;
alter role cycle_app set join_collapse_limit = 32;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
create table public.fc_a (id integer primary key, k integer not null);
create table public.fc_b (id integer primary key, k integer not null);
create table public.fc_c (id integer primary key, k integer not null);
create table public.fc_d (id integer primary key, k integer not null);
create table public.fc_e (id integer primary key, k integer not null);
insert into public.fc_a select g, g % 1000 from generate_series(1,30000) g;
insert into public.fc_b select g, g % 1000 from generate_series(1,30000) g;
insert into public.fc_c select g, g % 1000 from generate_series(1,30000) g;
insert into public.fc_d select g, g % 1000 from generate_series(1,30000) g;
insert into public.fc_e select g, case when g in (1000,2000,3000,4000,5000) then 1 else 999 end from generate_series(1,30000) g;
create index fc_a_k_idx on public.fc_a(k);
create index fc_b_k_idx on public.fc_b(k);
create index fc_c_k_idx on public.fc_c(k);
create index fc_d_k_idx on public.fc_d(k);
create index fc_e_k_idx on public.fc_e(k);
analyze public.fc_a; analyze public.fc_b; analyze public.fc_c; analyze public.fc_d; analyze public.fc_e;
grant usage on schema public to cycle_app;
grant select on public.products, public.fc_a, public.fc_b, public.fc_c, public.fc_d, public.fc_e to cycle_app;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

query_sql="select count(*) from (select a.id, a.k from public.fc_a a, public.fc_b b, public.fc_c c where a.id=b.id and b.id=c.id) s, public.fc_d d, public.fc_e e where s.id=d.id and d.id=e.id and e.k=1;"
setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "show from_collapse_limit;"; }
result() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "$query_sql"; }
plan() {
  local url="$1" rpc="$2"
  psql "$url" -X -v ON_ERROR_STOP=1 -At <<SQL
set random_page_cost=$rpc;
set max_parallel_workers_per_gather=0;
explain (costs on, summary off) $query_sql
SQL
}
matrix() {
  local url="$1"
  for rpc in 1.1 2 4 8 16; do
    echo "RPC=$rpc"
    plan "$url" "$rpc"
  done
}

src_setting="$(setting "$SRC_APP")"; dst_setting="$(setting "$DST_APP")"
src_result="$(result "$SRC_APP")"; dst_result="$(result "$DST_APP")"
printf 'BEFORE\nsource effective from_collapse_limit=%s\ndestination effective from_collapse_limit=%s\nsource result=%s\ndestination result=%s\n' "$src_setting" "$dst_setting" "$src_result" "$dst_result"
[[ "$src_setting" == 1 && "$dst_setting" == 8 ]] || { echo 'Fixture did not establish setting drift.' >&2; exit 2; }
[[ "$src_result" == "$dst_result" ]] || { echo 'Application result mismatch before sync.' >&2; exit 2; }
src_before="$(matrix "$SRC_APP")"; dst_before="$(matrix "$DST_APP")"
printf 'source planner matrix before:\n%s\ndestination planner matrix before:\n%s\n' "$src_before" "$dst_before"

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.fc_a,public.fc_b,public.fc_c,public.fc_d,public.fc_e' bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_FROM_COLLAPSE_LIMIT_COMMA_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'from_collapse_limit|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_COMMA_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_COMMA_FAIL_CLOSED=false'; exit 1
fi

appended="$(psql "$DST_ADMIN" -X -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=20001;")"
src_after_result="$(result "$SRC_APP")"; dst_after_result="$(result "$DST_APP")"
src_after="$(matrix "$SRC_APP")"; dst_after="$(matrix "$DST_APP")"
printf 'AFTER\nappended source row=%s\nsource result=%s\ndestination result=%s\nsource planner matrix after:\n%s\ndestination planner matrix after:\n%s\nNEON_ROLE_FROM_COLLAPSE_LIMIT_COMMA_SYNC_EXIT=%s\n' "$appended" "$src_after_result" "$dst_after_result" "$src_after" "$dst_after" "$rc"
[[ "$appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate source row did not synchronize.' >&2; exit 2; }
[[ "$src_result" == "$src_after_result" && "$dst_result" == "$dst_after_result" && "$src_after_result" == "$dst_after_result" ]] || { echo 'Application result changed.' >&2; exit 2; }
[[ "$src_before" == "$src_after" && "$dst_before" == "$dst_after" ]] || { echo 'Planner matrix not stable across sync.' >&2; exit 2; }
echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_COMMA_DETECTED=false'
if [[ "$src_after" != "$dst_after" ]]; then
  echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_COMMA_PLAN_DIVERGENCE=true'
  exit 1
fi
echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_COMMA_PLAN_DIVERGENCE=false'
exit 3

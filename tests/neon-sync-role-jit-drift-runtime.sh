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
alter role cycle_app set jit = off;
alter role cycle_app set jit_above_cost = 0;
alter role cycle_app set jit_inline_above_cost = 0;
alter role cycle_app set jit_optimize_above_cost = 0;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set jit = on;
alter role cycle_app set jit_above_cost = 0;
alter role cycle_app set jit_inline_above_cost = 0;
alter role cycle_app set jit_optimize_above_cost = 0;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.jit_probe (id bigint primary key, quantity integer not null, price numeric(12,2) not null);
grant usage on schema public to cycle_app;
grant select on public.products, public.jit_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.jit_probe
select g, (g % 97)::integer, ((g % 10000) / 100.0)::numeric(12,2) from generate_series(1,250000) g;
analyze public.products;
analyze public.jit_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'jit=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c 'show jit;'; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
query_result() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "select md5(sum((quantity::numeric * price) + sqrt(id::double precision))::text) from public.jit_probe where quantity between 10 and 90;"; }
query_plan() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "explain (analyze, buffers, verbose, costs on, summary on) select sum((quantity::numeric * price) + sqrt(id::double precision)) from public.jit_probe where quantity between 10 and 90;"; }

assert_jit_boundary() {
  local src_setting="$1" dst_setting="$2" src_row="$3" dst_row="$4" src_result="$5" dst_result="$6" src_plan="$7" dst_plan="$8"
  [[ "$src_setting" == 'off' ]] || return 1
  [[ "$dst_setting" == 'on' ]] || return 1
  [[ "$src_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ -n "$src_result" && "$src_result" == "$dst_result" ]] || return 1
  if grep -Eqi '(^|[[:space:]])JIT:' <<<"$src_plan"; then return 1; fi
  grep -Eqi '(^|[[:space:]])JIT:' <<<"$dst_plan" || return 1
  grep -Eqi 'Functions:|Timing:.*Generation|Options:.*Inlining' <<<"$dst_plan" || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
src_result="$(query_result "$SRC_APP")"; dst_result="$(query_result "$DST_APP")"
src_plan="$(query_plan "$SRC_APP")"; dst_plan="$(query_plan "$DST_APP")"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource result=%s\ndestination result=%s\nsource plan=%s\ndestination plan=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_result" "$dst_result" "$src_plan" "$dst_plan"
[[ "${src_catalog,,}" == 'jit=off' && "${dst_catalog,,}" == 'jit=on' ]] || { echo 'Catalog fixture did not persist both jit settings.' >&2; exit 2; }
assert_jit_boundary "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_result" "$dst_result" "$src_plan" "$dst_plan" || { echo 'Fixture did not establish the required jit application boundary.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_JIT_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi '(^|[^a-z])jit([^a-z]|$)|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_JIT_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_JIT_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"; dst_row_after="$(ordinary_row "$DST_APP")"
src_result_after="$(query_result "$SRC_APP")"; dst_result_after="$(query_result "$DST_APP")"
src_plan_after="$(query_plan "$SRC_APP")"; dst_plan_after="$(query_plan "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource result=%s\ndestination result=%s\nsource plan=%s\ndestination plan=%s\nNEON_ROLE_JIT_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$src_result_after" "$dst_result_after" "$src_plan_after" "$dst_plan_after" "$rc"
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_jit_boundary "$src_effective_after" "$dst_effective_after" "$src_row_after" "$dst_row_after" "$src_result_after" "$dst_result_after" "$src_plan_after" "$dst_plan_after" || { echo 'jit application boundary did not persist after sync.' >&2; exit 2; }
echo 'NEON_ROLE_JIT_DRIFT_DETECTED=false'
exit 1

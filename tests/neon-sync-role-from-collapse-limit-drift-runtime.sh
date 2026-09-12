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
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set from_collapse_limit = 8;
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
insert into public.fc_a select g, g % 100 from generate_series(1,5000) g;
insert into public.fc_b select g, case when g <= 100 then 1 else g % 100 end from generate_series(1,5000) g;
insert into public.fc_c select g, g % 50 from generate_series(1,5000) g;
insert into public.fc_d select g, g % 20 from generate_series(1,5000) g;
insert into public.fc_e select g, g % 10 from generate_series(1,5000) g;
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

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'from_collapse_limit=%';"
}
ordinary_row() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -c "select id || '|' || sku || '|' || quantity from public.products where id=15000;"
}
query_sql() {
  case "$1" in
    q1) cat <<'SQL'
select count(*) from (
  select a.id, a.k from public.fc_a a join public.fc_b b on b.id=a.id join public.fc_c c on c.id=a.id
) s join public.fc_d d on d.id=s.id where s.id <= 500 and d.k < 5;
SQL
      ;;
    q2) cat <<'SQL'
select count(*) from (
  select a.id, b.k as bk from public.fc_a a join public.fc_b b on b.id=a.id join public.fc_c c on c.k=b.k
) s join public.fc_d d on d.id=s.id join public.fc_e e on e.id=d.id where s.id <= 250 and s.bk = 1;
SQL
      ;;
    q3) cat <<'SQL'
select count(*) from public.fc_e e join (
  select a.id, c.k as ck from public.fc_a a join public.fc_b b on b.id=a.id join public.fc_c c on c.id=b.id
) s on s.id=e.id join public.fc_d d on d.k=s.ck where e.id <= 300;
SQL
      ;;
    q4) cat <<'SQL'
select count(*) from (
  select a.id, a.k from public.fc_a a join public.fc_b b on b.k=a.k
) ab join (
  select c.id, c.k from public.fc_c c join public.fc_d d on d.id=c.id
) cd on cd.id=ab.id join public.fc_e e on e.id=ab.id where ab.id <= 200;
SQL
      ;;
    *) return 2 ;;
  esac
}
plan_for() {
  local url="$1" q="$2" rpc="$3"
  local sql
  sql="$(query_sql "$q")"
  psql "$url" -X -v ON_ERROR_STOP=1 -At <<SQL
set random_page_cost=$rpc;
set max_parallel_workers_per_gather=0;
explain (costs on, summary off) $sql
SQL
}
result_for() {
  local url="$1" q="$2"
  local sql
  sql="$(query_sql "$q")"
  psql "$url" -X -v ON_ERROR_STOP=1 -At -c "$sql"
}
matrix() {
  local url="$1"
  local q rpc
  for q in q1 q2 q3 q4; do
    for rpc in 1.1 4 16; do
      printf 'CASE=%s RPC=%s\n' "$q" "$rpc"
      plan_for "$url" "$q" "$rpc"
    done
  done
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\n' "$src_setting" "$dst_setting" "$src_row" "$dst_row"
[[ "${src_setting,,}" == 'from_collapse_limit=1' && "${dst_setting,,}" == 'from_collapse_limit=8' ]] || { echo 'Fixture did not establish from_collapse_limit drift.' >&2; exit 2; }
[[ "$src_row" == '15000|SOURCE-SKU-15000|0' && "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || { echo 'Ordinary application state mismatch.' >&2; exit 2; }
for q in q1 q2 q3 q4; do
  s="$(result_for "$SRC_APP" "$q")"; d="$(result_for "$DST_APP" "$q")"
  printf 'before result %s source=%s destination=%s\n' "$q" "$s" "$d"
  [[ "$s" == "$d" ]] || { echo "Result mismatch for $q: source=$s destination=$d" >&2; exit 2; }
done
src_matrix_before="$(matrix "$SRC_APP")"
dst_matrix_before="$(matrix "$DST_APP")"
printf 'source planner matrix before:\n%s\ndestination planner matrix before:\n%s\n' "$src_matrix_before" "$dst_matrix_before"

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.fc_a,public.fc_b,public.fc_c,public.fc_d,public.fc_e' bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_FROM_COLLAPSE_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'from_collapse_limit|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
[[ "${dst_setting_after,,}" == 'from_collapse_limit=8' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
for q in q1 q2 q3 q4; do
  s="$(result_for "$SRC_APP" "$q")"; d="$(result_for "$DST_APP" "$q")"
  printf 'after result %s source=%s destination=%s\n' "$q" "$s" "$d"
  [[ "$s" == "$d" ]] || { echo "Result mismatch after sync for $q: source=$s destination=$d" >&2; exit 2; }
done
src_matrix_after="$(matrix "$SRC_APP")"
dst_matrix_after="$(matrix "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource planner matrix after:\n%s\ndestination planner matrix after:\n%s\nNEON_ROLE_FROM_COLLAPSE_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_appended" "$src_matrix_after" "$dst_matrix_after" "$rc"
[[ "$src_matrix_before" == "$src_matrix_after" && "$dst_matrix_before" == "$dst_matrix_after" ]] || { echo 'Planner matrix was not stable across synchronization.' >&2; exit 2; }

echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_DRIFT_DETECTED=false'
if [[ "$src_matrix_after" != "$dst_matrix_after" ]]; then
  echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_PLAN_DIVERGENCE=true'
  exit 1
fi
echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_PLAN_DIVERGENCE=false'
exit 3

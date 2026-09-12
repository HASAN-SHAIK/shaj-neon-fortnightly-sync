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
insert into public.fc_a select g, g % 100 from generate_series(1,5000) g;
insert into public.fc_b select g, g % 100 from generate_series(1,5000) g;
insert into public.fc_c select g, g % 100 from generate_series(1,5000) g;
analyze public.fc_a; analyze public.fc_b; analyze public.fc_c;
grant usage on schema public to cycle_app;
grant select on public.products, public.fc_a, public.fc_b, public.fc_c to cycle_app;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'from_collapse_limit=%';"
}
probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At <<'SQL'
show from_collapse_limit;
explain (analyze, costs off, summary off, timing off)
select count(*)
from (
  select a.id
  from public.fc_a a
  join public.fc_b b on b.id=a.id
  join public.fc_c c on c.id=a.id
) s
where s.id <= 100;
select count(*)
from (
  select a.id
  from public.fc_a a
  join public.fc_b b on b.id=a.id
  join public.fc_c c on c.id=a.id
) s
where s.id <= 100;
select id || '|' || sku || '|' || quantity from public.products where id=15000;
SQL
}
plan_from_probe() {
  # Probe layout is: setting line, EXPLAIN lines, count line, ordinary-row line.
  # Compare only EXPLAIN output so the intentionally different GUC setting
  # cannot itself be misclassified as a concrete execution-plan divergence.
  sed '1d' <<<"$1" | sed '$d' | sed '$d'
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app from-collapse probe=%s\ndestination app from-collapse probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'from_collapse_limit=1' && "${dst_setting,,}" == 'from_collapse_limit=8' ]] || { echo 'Fixture did not establish from_collapse_limit drift.' >&2; exit 2; }
grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$src_probe" || { echo 'Source ordinary application row missing.' >&2; exit 2; }
grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$dst_probe" || { echo 'Destination ordinary application row missing.' >&2; exit 2; }
src_count="$(tail -n 2 <<<"$src_probe" | head -n 1)"; dst_count="$(tail -n 2 <<<"$dst_probe" | head -n 1)"
[[ "$src_count" == '100' && "$dst_count" == '100' ]] || { echo "Join result mismatch: source=$src_count destination=$dst_count" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.fc_a,public.fc_b,public.fc_c' bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
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
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app from-collapse probe=%s\ndestination app from-collapse probe=%s\nNEON_ROLE_FROM_COLLAPSE_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'from_collapse_limit=8' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
src_count_after="$(tail -n 2 <<<"$src_after" | head -n 1)"; dst_count_after="$(tail -n 2 <<<"$dst_after" | head -n 1)"
[[ "$src_count_after" == '100' && "$dst_count_after" == '100' ]] || { echo 'Join result changed unexpectedly after sync.' >&2; exit 2; }

src_plan_after="$(plan_from_probe "$src_after")"
dst_plan_after="$(plan_from_probe "$dst_after")"
echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_DRIFT_DETECTED=false'
if [[ "$src_plan_after" != "$dst_plan_after" ]]; then
  echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_PLAN_DIVERGENCE=true'
  exit 1
fi
echo 'NEON_ROLE_FROM_COLLAPSE_LIMIT_PLAN_DIVERGENCE=false'
exit 3

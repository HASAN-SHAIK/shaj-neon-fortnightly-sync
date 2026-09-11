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
alter role cycle_app set constraint_exclusion = on;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set constraint_exclusion = off;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;

create table public.constraint_probe (
  id integer primary key,
  bucket integer not null check (bucket >= 0),
  payload text not null
);
insert into public.constraint_probe
select g, g % 100, repeat('x',64) from generate_series(1,200000) g;
analyze public.constraint_probe;

grant usage on schema public to cycle_app;
grant select on public.products, public.constraint_probe to cycle_app;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'constraint_exclusion=%';"
}
probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At <<'SQL'
show constraint_exclusion;
explain (analyze, costs off, summary off, timing off)
select count(*) from public.constraint_probe where bucket < 0;
select count(*) from public.constraint_probe where bucket < 0;
select id || '|' || sku || '|' || quantity from public.products where id=15000;
SQL
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app constraint probe=%s\ndestination app constraint probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'constraint_exclusion=on' && "${dst_setting,,}" == 'constraint_exclusion=off' ]] || { echo 'Fixture did not establish constraint_exclusion drift.' >&2; exit 2; }
grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$src_probe" || { echo 'Source ordinary application row missing.' >&2; exit 2; }
grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$dst_probe" || { echo 'Destination ordinary application row missing.' >&2; exit 2; }
src_count="$(tail -n 2 <<<"$src_probe" | head -n 1)"; dst_count="$(tail -n 2 <<<"$dst_probe" | head -n 1)"
[[ "$src_count" == '0' && "$dst_count" == '0' ]] || { echo "Impossible-predicate result mismatch: source=$src_count destination=$dst_count" >&2; exit 2; }
grep -Eq 'One-Time Filter: false|Result' <<<"$src_probe" || { echo 'Source did not eliminate impossible scan.' >&2; exit 2; }
if grep -Fq 'Seq Scan on constraint_probe' <<<"$src_probe"; then echo 'Source unexpectedly scanned constraint_probe.' >&2; exit 2; fi
grep -Fq 'Seq Scan on constraint_probe' <<<"$dst_probe" || { echo 'Destination did not execute the expected scan.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.constraint_probe' bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_CONSTRAINT_EXCLUSION_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'constraint_exclusion|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_CONSTRAINT_EXCLUSION_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_CONSTRAINT_EXCLUSION_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app constraint probe=%s\ndestination app constraint probe=%s\nNEON_ROLE_CONSTRAINT_EXCLUSION_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'constraint_exclusion=off' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
src_count_after="$(tail -n 2 <<<"$src_after" | head -n 1)"; dst_count_after="$(tail -n 2 <<<"$dst_after" | head -n 1)"
[[ "$src_count_after" == '0' && "$dst_count_after" == '0' ]] || { echo 'Impossible-predicate result changed unexpectedly after sync.' >&2; exit 2; }
grep -Eq 'One-Time Filter: false|Result' <<<"$src_after" || { echo 'Source no longer eliminates impossible scan after sync.' >&2; exit 2; }
if grep -Fq 'Seq Scan on constraint_probe' <<<"$src_after"; then echo 'Source unexpectedly scanned after sync.' >&2; exit 2; fi
grep -Fq 'Seq Scan on constraint_probe' <<<"$dst_after" || { echo 'Destination no longer scans after sync.' >&2; exit 2; }
echo 'NEON_ROLE_CONSTRAINT_EXCLUSION_DRIFT_DETECTED=false'
echo 'NEON_ROLE_CONSTRAINT_EXCLUSION_PLAN_DIVERGENCE=true'
exit 1

#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SETTING='gin_fuzzy_search_limit'

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set gin_fuzzy_search_limit = 0;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set gin_fuzzy_search_limit = 20;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.gin_fuzzy_probe (
  id bigint primary key,
  tags integer[] not null
);
create index gin_fuzzy_probe_tags_idx on public.gin_fuzzy_probe using gin (tags);
grant select on public.products, public.gin_fuzzy_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.gin_fuzzy_probe(id, tags)
select g, array[(g - 1) % 20] from generate_series(1,20000) g;
analyze public.gin_fuzzy_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like '${SETTING}=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c 'show gin_fuzzy_search_limit;'; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
application_search_probe() {
  psql "$1" -X -q -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
set enable_seqscan=off;
select current_setting('gin_fuzzy_search_limit'), count(*)
from public.gin_fuzzy_probe
where tags && array[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19];
SQL
}
application_plan_probe() {
  psql "$1" -X -q -v ON_ERROR_STOP=1 -At <<'SQL'
set enable_seqscan=off;
explain (costs off)
select id from public.gin_fuzzy_probe
where tags && array[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19];
SQL
}

assert_runtime_boundary() {
  local src_setting="$1" dst_setting="$2" src_row="$3" dst_row="$4" src_probe="$5" dst_probe="$6" src_plan="$7" dst_plan="$8"
  [[ "$src_setting" == '0' ]] || return 1
  [[ "$dst_setting" == '20' ]] || return 1
  [[ "$src_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  local src_count dst_count
  src_count="${src_probe##*|}"
  dst_count="${dst_probe##*|}"
  [[ "$src_probe" == 0\|* ]] || return 1
  [[ "$dst_probe" == 20\|* ]] || return 1
  [[ "$src_count" == '20000' ]] || return 1
  [[ "$dst_count" =~ ^[0-9]+$ ]] || return 1
  (( dst_count > 0 && dst_count < src_count && dst_count < 2000 )) || return 1
  grep -Eq 'Bitmap Index Scan|Index Scan' <<<"$src_plan" || return 1
  grep -Eq 'Bitmap Index Scan|Index Scan' <<<"$dst_plan" || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
src_probe="$(application_search_probe "$SRC_APP")"; dst_probe="$(application_search_probe "$DST_APP")"
src_plan="$(application_plan_probe "$SRC_APP")"; dst_plan="$(application_plan_probe "$DST_APP")"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource search probe=%s\ndestination search probe=%s\nsource plan=%s\ndestination plan=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe" "$src_plan" "$dst_plan"
[[ "${src_catalog,,}" == ${SETTING}=0 && "${dst_catalog,,}" == ${SETTING}=20 ]] || { echo 'Catalog fixture did not persist both gin_fuzzy_search_limit role settings.' >&2; exit 2; }
assert_runtime_boundary "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe" "$src_plan" "$dst_plan" || { echo 'Fixture did not establish required multi-key GIN fuzzy-search result boundary.' >&2; exit 2; }

set +e
out="$(EXCLUDED_TABLES='public.gin_fuzzy_probe' SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_GIN_FUZZY_SEARCH_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'gin_fuzzy_search_limit|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_GIN_FUZZY_SEARCH_LIMIT_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_GIN_FUZZY_SEARCH_LIMIT_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"; dst_row_after="$(ordinary_row "$DST_APP")"
src_probe_after="$(application_search_probe "$SRC_APP")"; dst_probe_after="$(application_search_probe "$DST_APP")"
src_plan_after="$(application_plan_probe "$SRC_APP")"; dst_plan_after="$(application_plan_probe "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource search probe=%s\ndestination search probe=%s\nsource plan=%s\ndestination plan=%s\nNEON_ROLE_GIN_FUZZY_SEARCH_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$src_probe_after" "$dst_probe_after" "$src_plan_after" "$dst_plan_after" "$rc"
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_runtime_boundary "$src_effective_after" "$dst_effective_after" "$src_row_after" "$dst_row_after" "$src_probe_after" "$dst_probe_after" "$src_plan_after" "$dst_plan_after" || { echo 'Multi-key GIN fuzzy-search result boundary did not persist after sync.' >&2; exit 2; }
echo 'NEON_ROLE_GIN_FUZZY_SEARCH_LIMIT_DRIFT_DETECTED=false'
exit 1

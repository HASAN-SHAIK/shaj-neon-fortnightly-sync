#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SETTING='default_transaction_isolation'

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set default_transaction_isolation = 'read committed';
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set default_transaction_isolation = 'repeatable read';
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select, update on public.products to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
analyze public.products;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like '${SETTING}=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "show ${SETTING};"; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
reset_probe_row() { psql "$1" -X -v ON_ERROR_STOP=1 -qAt -c 'update public.products set quantity=10 where id=42;'; }

isolation_probe() {
  local app_url="$1" admin_url="$2" tmp_sql tmp_out rc out
  reset_probe_row "$admin_url"
  tmp_sql="$(mktemp)"
  tmp_out="$(mktemp)"
  cat >"$tmp_sql" <<'PSQL'
\set ON_ERROR_STOP on
begin;
show transaction_isolation;
select 'first=' || quantity from public.products where id=42;
\! sleep 0.35
select 'second=' || quantity from public.products where id=42;
commit;
PSQL
  set +e
  psql "$app_url" -X -f "$tmp_sql" >"$tmp_out" 2>&1 &
  local reader_pid=$!
  sleep 0.12
  psql "$admin_url" -X -v ON_ERROR_STOP=1 -qAt -c 'update public.products set quantity=99 where id=42;' >/dev/null 2>&1
  wait "$reader_pid"
  rc=$?
  set -e
  out="$(tr '\n' ';' <"$tmp_out")"
  rm -f "$tmp_sql" "$tmp_out"
  printf '%s|%s\n' "$rc" "$out"
}

assert_runtime_boundary() {
  local src_setting="$1" dst_setting="$2" src_row="$3" dst_row="$4" src_probe="$5" dst_probe="$6"
  [[ "$src_setting" == 'read committed' ]] || return 1
  [[ "$dst_setting" == 'repeatable read' ]] || return 1
  [[ "$src_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  grep -Eq '^0\|' <<<"$src_probe" || return 1
  grep -Fq 'read committed' <<<"$src_probe" || return 1
  grep -Fq 'first=10' <<<"$src_probe" || return 1
  grep -Fq 'second=99' <<<"$src_probe" || return 1
  grep -Eq '^0\|' <<<"$dst_probe" || return 1
  grep -Fq 'repeatable read' <<<"$dst_probe" || return 1
  grep -Fq 'first=10' <<<"$dst_probe" || return 1
  grep -Fq 'second=10' <<<"$dst_probe" || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
src_probe="$(isolation_probe "$SRC_APP" "$SRC_ADMIN")"; dst_probe="$(isolation_probe "$DST_APP" "$DST_ADMIN")"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource isolation probe=%s\ndestination isolation probe=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe"
[[ "${src_catalog,,}" == ${SETTING}=* && "${dst_catalog,,}" == ${SETTING}=* ]] || { echo 'Catalog fixture did not persist both role settings.' >&2; exit 2; }
assert_runtime_boundary "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe" || { echo 'Fixture did not establish the required transaction-isolation application boundary.' >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_DEFAULT_TRANSACTION_ISOLATION_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'default_transaction_isolation|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_DEFAULT_TRANSACTION_ISOLATION_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_DEFAULT_TRANSACTION_ISOLATION_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"; dst_row_after="$(ordinary_row "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_probe_after="$(isolation_probe "$SRC_APP" "$SRC_ADMIN")"; dst_probe_after="$(isolation_probe "$DST_APP" "$DST_ADMIN")"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource isolation probe=%s\ndestination isolation probe=%s\nNEON_ROLE_DEFAULT_TRANSACTION_ISOLATION_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$src_probe_after" "$dst_probe_after" "$rc"
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_runtime_boundary "$src_effective_after" "$dst_effective_after" "$src_row_after" "$dst_row_after" "$src_probe_after" "$dst_probe_after" || { echo 'Transaction-isolation application boundary did not persist after sync.' >&2; exit 2; }
echo 'NEON_ROLE_DEFAULT_TRANSACTION_ISOLATION_DRIFT_DETECTED=false'
exit 1

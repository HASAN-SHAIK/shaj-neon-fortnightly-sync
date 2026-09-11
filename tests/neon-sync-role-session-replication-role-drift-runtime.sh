#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"

SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SETTING='session_replication_role'

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set session_replication_role = 'origin';
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set session_replication_role = 'replica';
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.categories (
  id bigint primary key,
  name text not null
);
create table public.products (
  id bigint primary key,
  sku text not null,
  category_id bigint not null references public.categories(id)
);
grant usage on schema public to cycle_app;
grant select on public.categories, public.products to cycle_app;
grant insert on public.products to cycle_app;
insert into public.categories values (1,'General');
insert into public.products values (1,'BASE-SKU-1',1);
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (2,'SOURCE-SKU-2',1);"

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like '${SETTING}=%';"
}
effective_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "show session_replication_role;"
}
ordinary_row() {
  psql "$1" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,category_id from public.products where id=1;"
}
orphan_probe() {
  local url="$1" id="$2" sku="$3" out rc row
  set +e
  out="$(psql "$url" -v ON_ERROR_STOP=1 -At -c "insert into public.products(id,sku,category_id) values (${id},'${sku}',999);" 2>&1)"
  rc=$?
  set -e
  row="$(psql "${url/cycle_app/postgres}" -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,category_id from public.products where id=${id};" 2>/dev/null || true)"
  printf '%s|%s|%s' "$rc" "${out//$'\n'/ }" "$row"
}

assert_boundary() {
  local src_setting="$1" dst_setting="$2" src_probe="$3" dst_probe="$4" src_row="$5" dst_row="$6"
  [[ "$src_setting" == 'origin' ]] || return 1
  [[ "$dst_setting" == 'replica' ]] || return 1
  [[ "$src_row" == '1|BASE-SKU-1|1' && "$dst_row" == '1|BASE-SKU-1|1' ]] || return 1
  [[ "$src_probe" != 0\|* ]] || return 1
  grep -qi 'foreign key constraint' <<<"$src_probe" || return 1
  [[ "$dst_probe" == 0\|*"|999" ]] || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"
dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"
dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"
dst_row="$(ordinary_row "$DST_APP")"
src_probe="$(orphan_probe "$SRC_APP" 90001 'SOURCE-ORPHAN-90001')"
dst_probe="$(orphan_probe "$DST_APP" 90001 'DEST-ORPHAN-90001')"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource orphan probe=%s\ndestination orphan probe=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe"
[[ "${src_catalog,,}" == ${SETTING}=origin && "${dst_catalog,,}" == ${SETTING}=replica ]] || { echo 'Catalog fixture did not persist both session_replication_role settings.' >&2; exit 2; }
assert_boundary "$src_effective" "$dst_effective" "$src_probe" "$dst_probe" "$src_row" "$dst_row" || { echo 'Fixture did not establish required foreign-key enforcement boundary.' >&2; exit 2; }

# Restore equal product state before invoking the real production synchronization path.
psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -c 'delete from public.products where id=90001;' >/dev/null

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"
rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_SESSION_REPLICATION_ROLE_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'session_replication_role|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_SESSION_REPLICATION_ROLE_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_SESSION_REPLICATION_ROLE_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,category_id from public.products where id=2;')"
dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"
dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"
dst_row_after="$(ordinary_row "$DST_APP")"
src_probe_after="$(orphan_probe "$SRC_APP" 90002 'SOURCE-ORPHAN-90002')"
dst_probe_after="$(orphan_probe "$DST_APP" 90002 'DEST-ORPHAN-90002')"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource orphan probe=%s\ndestination orphan probe=%s\nNEON_ROLE_SESSION_REPLICATION_ROLE_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$src_probe_after" "$dst_probe_after" "$rc"
[[ "$dst_appended" == '2|SOURCE-SKU-2|1' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_boundary "$src_effective_after" "$dst_effective_after" "$src_probe_after" "$dst_probe_after" "$src_row_after" "$dst_row_after" || { echo 'Foreign-key enforcement boundary did not persist after sync.' >&2; exit 2; }
echo 'NEON_ROLE_SESSION_REPLICATION_ROLE_DRIFT_DETECTED=false'
exit 1

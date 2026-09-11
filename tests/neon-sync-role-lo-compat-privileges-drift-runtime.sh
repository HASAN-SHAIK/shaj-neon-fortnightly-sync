#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SETTING='lo_compat_privileges'

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set lo_compat_privileges = off;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set lo_compat_privileges = on;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
grant select on public.products to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
begin;
select lo_create(90001);
select lowrite(lo_open(90001, 131072), convert_to('SHAJ-SECRET-LARGE-OBJECT','UTF8'));
commit;
revoke all on large object 90001 from public;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like '${SETTING}=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c 'show lo_compat_privileges;'; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
large_object_probe() {
  local url="$1" out rc
  set +e
  out="$(psql "$url" -X -q -v ON_ERROR_STOP=1 -At <<'SQL' 2>&1
begin;
select current_setting('lo_compat_privileges') || '|' || encode(loread(lo_open(90001, 262144), 1024),'escape');
commit;
SQL
)"
  rc=$?
  set -e
  printf '%s|%s\n' "$rc" "$(tr '\n' ';' <<<"$out")"
}

assert_runtime_boundary() {
  local src_setting="$1" dst_setting="$2" src_row="$3" dst_row="$4" src_probe="$5" dst_probe="$6"
  [[ "$src_setting" == 'off' ]] || return 1
  [[ "$dst_setting" == 'on' ]] || return 1
  [[ "$src_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$src_probe" != 0\|* ]] || return 1
  grep -Eqi 'permission denied for large object|must be owner of large object' <<<"$src_probe" || return 1
  [[ "$dst_probe" == 0\|* ]] || return 1
  grep -Fq 'on|SHAJ-SECRET-LARGE-OBJECT' <<<"$dst_probe" || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
src_probe="$(large_object_probe "$SRC_APP")"; dst_probe="$(large_object_probe "$DST_APP")"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource large-object probe=%s\ndestination large-object probe=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe"
[[ "${src_catalog,,}" == ${SETTING}=off && "${dst_catalog,,}" == ${SETTING}=on ]] || { echo 'Catalog fixture did not persist both lo_compat_privileges role settings.' >&2; exit 2; }
assert_runtime_boundary "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe" || { echo 'Fixture did not establish the large-object access-control boundary.' >&2; exit 2; }

# Remove only the destination fixture copy before production sync so pg_dump can restore
# source large-object state without an artificial duplicate-OID collision.
psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -c 'select lo_unlink(90001);' >/dev/null

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_LO_COMPAT_PRIVILEGES_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'lo_compat_privileges|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_LO_COMPAT_PRIVILEGES_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_LO_COMPAT_PRIVILEGES_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"; dst_row_after="$(ordinary_row "$DST_APP")"
src_probe_after="$(large_object_probe "$SRC_APP")"; dst_probe_after="$(large_object_probe "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource large-object probe=%s\ndestination large-object probe=%s\nNEON_ROLE_LO_COMPAT_PRIVILEGES_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$src_probe_after" "$dst_probe_after" "$rc"
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_runtime_boundary "$src_effective_after" "$dst_effective_after" "$src_row_after" "$dst_row_after" "$src_probe_after" "$dst_probe_after" || { echo 'Large-object access-control boundary did not persist after sync.' >&2; exit 2; }
echo 'NEON_ROLE_LO_COMPAT_PRIVILEGES_DRIFT_DETECTED=false'
exit 1

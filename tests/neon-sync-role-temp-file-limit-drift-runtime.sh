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
alter role cycle_app set work_mem = '64kB';
alter role cycle_app set temp_file_limit = '-1';
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set work_mem = '64kB';
alter role cycle_app set temp_file_limit = '1MB';
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.temp_file_probe (id bigint primary key, payload text not null);
grant usage on schema public to cycle_app;
grant select on public.products, public.temp_file_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.temp_file_probe
select g, md5(g::text) || md5((g * 17)::text) || md5((g * 31)::text) || md5((g * 47)::text)
from generate_series(1,120000) g;
analyze public.products;
analyze public.temp_file_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and (lower(cfg) like 'temp_file_limit=%' or lower(cfg) like 'work_mem=%') order by cfg;"
}

ordinary_row() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=15000;"
}

sort_probe() {
  local url="$1"
  local tmp rc
  tmp="$(mktemp)"
  set +e
  psql "$url" -X -v ON_ERROR_STOP=1 -At -c "select md5(string_agg(id::text || ':' || payload, ',' order by payload,id)) from public.temp_file_probe;" >"$tmp" 2>&1
  rc=$?
  set -e
  printf '%s|' "$rc"
  tr '\n' ';' <"$tmp"
  rm -f "$tmp"
  printf '\n'
}

assert_source_probe() {
  local v="$1"
  [[ "$v" == 0\|* ]] || return 1
  grep -Eq '^0\|[0-9a-f]{32};$' <<<"$v" || return 1
}

assert_destination_probe() {
  local v="$1"
  [[ "$v" != 0\|* ]] || return 1
  grep -Eqi 'temporary file size exceeds "?temp_file_limit"?' <<<"$v" || return 1
}

src_setting="$(role_setting "$SRC_ADMIN")"
dst_setting="$(role_setting "$DST_ADMIN")"
src_row="$(ordinary_row "$SRC_APP")"
dst_row="$(ordinary_row "$DST_APP")"
src_probe="$(sort_probe "$SRC_APP")"
dst_probe="$(sort_probe "$DST_APP")"
printf 'BEFORE\nsource role settings=%s\ndestination role settings=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource app temp-file probe=%s\ndestination app temp-file probe=%s\n' "$src_setting" "$dst_setting" "$src_row" "$dst_row" "$src_probe" "$dst_probe"

grep -Fxiq 'temp_file_limit=-1' <<<"$src_setting" || { echo 'Source fixture did not establish unlimited temp_file_limit.' >&2; exit 2; }
grep -Fxiq 'temp_file_limit=1MB' <<<"$dst_setting" || { echo 'Destination fixture did not establish 1MB temp_file_limit.' >&2; exit 2; }
grep -Fxiq 'work_mem=64kB' <<<"$src_setting" || { echo 'Source work_mem fixture mismatch.' >&2; exit 2; }
grep -Fxiq 'work_mem=64kB' <<<"$dst_setting" || { echo 'Destination work_mem fixture mismatch.' >&2; exit 2; }
[[ "$src_row" == '15000|SOURCE-SKU-15000|0' && "$dst_row" == "$src_row" ]] || { echo 'Ordinary application baseline differs.' >&2; exit 2; }
assert_source_probe "$src_probe" || { echo "Source temp-file probe did not succeed: $src_probe" >&2; exit 2; }
assert_destination_probe "$dst_probe" || { echo "Destination temp-file probe did not hit temp_file_limit: $dst_probe" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.temp_file_probe' bash scripts/neon-sync/append-sync.sh 2>&1)"
rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_TEMP_FILE_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'temp_file_limit|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_TEMP_FILE_LIMIT_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_TEMP_FILE_LIMIT_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_synced_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(sort_probe "$SRC_APP")"
dst_after="$(sort_probe "$DST_APP")"
printf 'AFTER\ndestination role settings=%s\nappended source row=%s\nsource app temp-file probe=%s\ndestination app temp-file probe=%s\nNEON_ROLE_TEMP_FILE_LIMIT_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_synced_row" "$src_after" "$dst_after" "$rc"

grep -Fxiq 'temp_file_limit=1MB' <<<"$dst_setting_after" || { echo 'Destination temp_file_limit changed unexpectedly.' >&2; exit 2; }
[[ "$dst_synced_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_source_probe "$src_after" || { echo 'Source temp-file behavior did not persist.' >&2; exit 2; }
assert_destination_probe "$dst_after" || { echo 'Destination temp-file behavior did not persist.' >&2; exit 2; }
echo 'NEON_ROLE_TEMP_FILE_LIMIT_DRIFT_DETECTED=false'
exit 1

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
alter role cycle_app set compute_query_id = on;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set compute_query_id = off;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'compute_query_id=%';"
}
probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At <<'SQL'
show compute_query_id;
select case when query_id is null then 'NULL' else 'NONNULL' end from pg_stat_activity where pid=pg_backend_pid();
select id || '|' || sku || '|' || quantity from public.products where id=15000;
SQL
}
assert_source() { grep -Fxiq 'on' <<<"$1" && grep -Fxq 'NONNULL' <<<"$1" && grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$1"; }
assert_destination() { grep -Fxiq 'off' <<<"$1" && grep -Fxq 'NULL' <<<"$1" && grep -Fxq '15000|SOURCE-SKU-15000|0' <<<"$1"; }

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app query-id probe=%s\ndestination app query-id probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'compute_query_id=on' && "${dst_setting,,}" == 'compute_query_id=off' ]] || { echo 'Fixture did not establish compute_query_id drift.' >&2; exit 2; }
assert_source "$src_probe" || { echo "Source query-id observation invalid: $src_probe" >&2; exit 2; }
assert_destination "$dst_probe" || { echo "Destination query-id observation invalid: $dst_probe" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_COMPUTE_QUERY_ID_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'compute_query_id|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_COMPUTE_QUERY_ID_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_COMPUTE_QUERY_ID_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app query-id probe=%s\ndestination app query-id probe=%s\nNEON_ROLE_COMPUTE_QUERY_ID_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'compute_query_id=off' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_source "$src_after" || { echo 'Source query-id behavior did not persist.' >&2; exit 2; }
assert_destination "$dst_after" || { echo 'Destination query-id behavior did not persist.' >&2; exit 2; }
echo 'NEON_ROLE_COMPUTE_QUERY_ID_DRIFT_DETECTED=false'
exit 1

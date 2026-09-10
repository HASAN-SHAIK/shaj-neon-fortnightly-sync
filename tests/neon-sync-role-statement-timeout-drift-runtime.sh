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
alter role cycle_app set statement_timeout = 0;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set statement_timeout = '100ms';
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
grant usage on schema public to cycle_app;
grant select on public.products to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
analyze public.products;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'statement_timeout=%';"
}

probe() {
  local url="$1"
  local tmp
  tmp="$(mktemp)"
  set +e
  psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' >"$tmp" 2>&1 <<'SQL'
show statement_timeout;
select pg_sleep(0.25), count(*) from public.products;
select id,sku,quantity from public.products where id=15000;
SQL
  local rc=$?
  set -e
  local out
  out="$(cat "$tmp")"
  rm -f "$tmp"
  printf '%s|%s\n' "$rc" "$out"
}

assert_source() {
  local v="$1"
  grep -Eq '^0\|0([|]|$)' <<<"$v" || return 1
  grep -Eq '(^|[|])20000($|[|])' <<<"$v" || return 1
  grep -Fq '15000|SOURCE-SKU-15000|0' <<<"$v" || return 1
}
assert_destination() {
  local v="$1"
  grep -Eq '^[1-9][0-9]*\|' <<<"$v" || return 1
  grep -Eqi 'canceling statement due to statement timeout' <<<"$v" || return 1
  ! grep -Fq '15000|SOURCE-SKU-15000|0' <<<"$v" || return 1
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app statement-timeout probe=%s\ndestination app statement-timeout probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'statement_timeout=0' ]] || { echo 'Source fixture did not establish unlimited statement_timeout.' >&2; exit 2; }
[[ "${dst_setting,,}" == 'statement_timeout=100ms' ]] || { echo 'Destination fixture did not establish 100ms statement_timeout.' >&2; exit 2; }
assert_source "$src_probe" || { echo "Source application probe did not complete under statement_timeout=0: $src_probe" >&2; exit 2; }
assert_destination "$dst_probe" || { echo "Destination application probe did not time out as required: $dst_probe" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_STATEMENT_TIMEOUT_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'statement_timeout|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_STATEMENT_TIMEOUT_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_STATEMENT_TIMEOUT_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app statement-timeout probe=%s\ndestination app statement-timeout probe=%s\nNEON_ROLE_STATEMENT_TIMEOUT_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'statement_timeout=100ms' ]] || { echo 'Destination statement_timeout changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_source "$src_after" || { echo 'Source statement_timeout behavior did not persist.' >&2; exit 2; }
assert_destination "$dst_after" || { echo 'Destination statement_timeout behavior did not persist.' >&2; exit 2; }
echo 'NEON_ROLE_STATEMENT_TIMEOUT_DRIFT_DETECTED=false'
exit 1

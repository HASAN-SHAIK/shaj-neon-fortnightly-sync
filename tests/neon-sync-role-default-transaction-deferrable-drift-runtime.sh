#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
SRC_ROOT='postgresql://postgres@127.0.0.1:55432/postgres'
DST_ROOT='postgresql://postgres@127.0.0.1:55433/postgres'
SRC_ADMIN='postgresql://postgres@127.0.0.1:55432/cycle_d_source'
DST_ADMIN='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SRC_APP='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'
DST_APP='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
SETTING='default_transaction_deferrable'
WRITER_SLEEP_SECONDS=3
WRITER_SETTLE_SECONDS=0.5
SOURCE_WAIT_MIN_MS=1800
DESTINATION_WAIT_MAX_MS=1500

psql "$SRC_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set default_transaction_isolation = 'serializable';
alter role cycle_app set default_transaction_read_only = on;
alter role cycle_app set default_transaction_deferrable = on;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set default_transaction_isolation = 'serializable';
alter role cycle_app set default_transaction_read_only = on;
alter role cycle_app set default_transaction_deferrable = off;
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

catalog_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like '${SETTING}=%';"
}
effective_setting() { psql "$1" -X -v ON_ERROR_STOP=1 -At -c "show ${SETTING};"; }
ordinary_row() { psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;'; }
transaction_probe() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At <<'SQL'
begin;
show transaction_isolation;
show transaction_read_only;
show transaction_deferrable;
select id || '|' || sku || '|' || quantity from public.products where id=15000;
commit;
SQL
}

safe_snapshot_probe() {
  local admin_url="$1" app_url="$2" label="$3"
  local writer_log reader_log writer_pid start_ms end_ms elapsed_ms
  writer_log="$(mktemp)"
  reader_log="$(mktemp)"

  (
    psql "$admin_url" -X -v ON_ERROR_STOP=1 -At >"$writer_log" 2>&1 <<SQL
begin isolation level serializable;
update public.products set quantity = quantity where id = 19999;
select 'writer-ready';
select pg_sleep(${WRITER_SLEEP_SECONDS});
commit;
SQL
  ) &
  writer_pid=$!

  sleep "$WRITER_SETTLE_SECONDS"
  kill -0 "$writer_pid" 2>/dev/null || {
    cat "$writer_log" >&2
    rm -f "$writer_log" "$reader_log"
    return 2
  }

  start_ms="$(date +%s%3N)"
  psql "$app_url" -X -v ON_ERROR_STOP=1 -At >"$reader_log" 2>&1 <<'SQL'
begin;
show transaction_isolation;
show transaction_read_only;
show transaction_deferrable;
select id || '|' || sku || '|' || quantity from public.products where id=15000;
commit;
SQL
  end_ms="$(date +%s%3N)"
  elapsed_ms=$((end_ms - start_ms))

  wait "$writer_pid"
  grep -Fxq 'writer-ready' "$writer_log" || {
    cat "$writer_log" >&2
    rm -f "$writer_log" "$reader_log"
    return 2
  }
  grep -Fq '15000|SOURCE-SKU-15000|0' "$reader_log" || {
    cat "$reader_log" >&2
    rm -f "$writer_log" "$reader_log"
    return 2
  }

  printf '%s safe snapshot elapsed_ms=%s probe=%s\n' "$label" "$elapsed_ms" "$(tr '\n' ';' <"$reader_log")"
  rm -f "$writer_log" "$reader_log"
  printf '%s\n' "$elapsed_ms"
}

assert_boundary() {
  local src_setting="$1" dst_setting="$2" src_row="$3" dst_row="$4" src_probe="$5" dst_probe="$6"
  [[ "$src_setting" == 'on' ]] || return 1
  [[ "$dst_setting" == 'off' ]] || return 1
  [[ "$src_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  [[ "$dst_row" == '15000|SOURCE-SKU-15000|0' ]] || return 1
  grep -Fq 'serializable' <<<"$src_probe" || return 1
  grep -Fq $'on\non' <<<"$src_probe" || return 1
  grep -Fq '15000|SOURCE-SKU-15000|0' <<<"$src_probe" || return 1
  grep -Fq 'serializable' <<<"$dst_probe" || return 1
  grep -Fq $'on\noff' <<<"$dst_probe" || return 1
  grep -Fq '15000|SOURCE-SKU-15000|0' <<<"$dst_probe" || return 1
}

assert_blocking_effect() {
  local src_ms="$1" dst_ms="$2"
  (( src_ms >= SOURCE_WAIT_MIN_MS )) || return 1
  (( dst_ms <= DESTINATION_WAIT_MAX_MS )) || return 1
  (( src_ms > dst_ms + 1000 )) || return 1
}

src_catalog="$(catalog_setting "$SRC_ADMIN")"; dst_catalog="$(catalog_setting "$DST_ADMIN")"
src_effective="$(effective_setting "$SRC_APP")"; dst_effective="$(effective_setting "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"; dst_row="$(ordinary_row "$DST_APP")"
src_probe="$(transaction_probe "$SRC_APP")"; dst_probe="$(transaction_probe "$DST_APP")"
printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nsource ordinary row=%s\ndestination ordinary row=%s\nsource transaction probe=%s\ndestination transaction probe=%s\n' "$src_catalog" "$dst_catalog" "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$(tr '\n' ';' <<<"$src_probe")" "$(tr '\n' ';' <<<"$dst_probe")"
[[ "${src_catalog,,}" == ${SETTING}=on && "${dst_catalog,,}" == ${SETTING}=off ]] || { echo 'Catalog fixture did not persist both role settings.' >&2; exit 2; }
assert_boundary "$src_effective" "$dst_effective" "$src_row" "$dst_row" "$src_probe" "$dst_probe" || { echo 'Fixture did not establish the required default-transaction-deferrable boundary.' >&2; exit 2; }

src_wait_output="$(safe_snapshot_probe "$SRC_ADMIN" "$SRC_APP" 'source-before')" || { echo 'Source safe-snapshot probe failed.' >&2; exit 2; }
dst_wait_output="$(safe_snapshot_probe "$DST_ADMIN" "$DST_APP" 'destination-before')" || { echo 'Destination safe-snapshot probe failed.' >&2; exit 2; }
printf '%s\n%s\n' "$src_wait_output" "$dst_wait_output"
src_wait_ms="$(tail -n1 <<<"$src_wait_output")"
dst_wait_ms="$(tail -n1 <<<"$dst_wait_output")"
[[ "$src_wait_ms" =~ ^[0-9]+$ && "$dst_wait_ms" =~ ^[0-9]+$ ]] || { echo 'Safe-snapshot timing evidence was not numeric.' >&2; exit 2; }
assert_blocking_effect "$src_wait_ms" "$dst_wait_ms" || { echo "Concurrent safe-snapshot effect was not reproduced before sync: source=${src_wait_ms}ms destination=${dst_wait_ms}ms" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'default_transaction_deferrable|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_DRIFT_FAIL_CLOSED=true'; exit 0
  fi
  echo 'NEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_catalog_after="$(catalog_setting "$DST_ADMIN")"
src_effective_after="$(effective_setting "$SRC_APP")"; dst_effective_after="$(effective_setting "$DST_APP")"
src_row_after="$(ordinary_row "$SRC_APP")"; dst_row_after="$(ordinary_row "$DST_APP")"
dst_appended="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_probe_after="$(transaction_probe "$SRC_APP")"; dst_probe_after="$(transaction_probe "$DST_APP")"
printf 'AFTER\ndestination catalog setting=%s\nsource effective setting=%s\ndestination effective setting=%s\nappended source row=%s\nsource transaction probe=%s\ndestination transaction probe=%s\nNEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_DRIFT_SYNC_EXIT=%s\n' "$dst_catalog_after" "$src_effective_after" "$dst_effective_after" "$dst_appended" "$(tr '\n' ';' <<<"$src_probe_after")" "$(tr '\n' ';' <<<"$dst_probe_after")" "$rc"
[[ "$dst_appended" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
assert_boundary "$src_effective_after" "$dst_effective_after" "$src_row_after" "$dst_row_after" "$src_probe_after" "$dst_probe_after" || { echo 'Default-transaction-deferrable boundary did not persist after sync.' >&2; exit 2; }

src_wait_after_output="$(safe_snapshot_probe "$SRC_ADMIN" "$SRC_APP" 'source-after')" || { echo 'Source post-sync safe-snapshot probe failed.' >&2; exit 2; }
dst_wait_after_output="$(safe_snapshot_probe "$DST_ADMIN" "$DST_APP" 'destination-after')" || { echo 'Destination post-sync safe-snapshot probe failed.' >&2; exit 2; }
printf '%s\n%s\n' "$src_wait_after_output" "$dst_wait_after_output"
src_wait_after_ms="$(tail -n1 <<<"$src_wait_after_output")"
dst_wait_after_ms="$(tail -n1 <<<"$dst_wait_after_output")"
[[ "$src_wait_after_ms" =~ ^[0-9]+$ && "$dst_wait_after_ms" =~ ^[0-9]+$ ]] || { echo 'Post-sync safe-snapshot timing evidence was not numeric.' >&2; exit 2; }
assert_blocking_effect "$src_wait_after_ms" "$dst_wait_after_ms" || { echo "Concurrent safe-snapshot effect did not persist after sync: source=${src_wait_after_ms}ms destination=${dst_wait_after_ms}ms" >&2; exit 2; }

echo 'NEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_DRIFT_DETECTED=false'
echo 'NEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_BLOCKING_EFFECT_VERIFIED=true'
printf 'NEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_SOURCE_WAIT_MS=%s\n' "$src_wait_after_ms"
printf 'NEON_ROLE_DEFAULT_TRANSACTION_DEFERRABLE_DESTINATION_WAIT_MS=%s\n' "$dst_wait_after_ms"
exit 1

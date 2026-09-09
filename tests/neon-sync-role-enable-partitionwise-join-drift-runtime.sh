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
alter role cycle_app set enable_partitionwise_join = on;
alter role cycle_app set enable_hashjoin = on;
alter role cycle_app set enable_mergejoin = off;
alter role cycle_app set enable_nestloop = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_partitionwise_join = off;
alter role cycle_app set enable_hashjoin = on;
alter role cycle_app set enable_mergejoin = off;
alter role cycle_app set enable_nestloop = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.pwj_orders (
  id integer not null,
  bucket integer not null,
  amount integer not null
) partition by range (bucket);
create table public.pwj_orders_p1 partition of public.pwj_orders for values from (0) to (25);
create table public.pwj_orders_p2 partition of public.pwj_orders for values from (25) to (50);
create table public.pwj_orders_p3 partition of public.pwj_orders for values from (50) to (75);
create table public.pwj_orders_p4 partition of public.pwj_orders for values from (75) to (100);
create table public.pwj_inventory (
  id integer not null,
  bucket integer not null,
  quantity integer not null
) partition by range (bucket);
create table public.pwj_inventory_p1 partition of public.pwj_inventory for values from (0) to (25);
create table public.pwj_inventory_p2 partition of public.pwj_inventory for values from (25) to (50);
create table public.pwj_inventory_p3 partition of public.pwj_inventory for values from (50) to (75);
create table public.pwj_inventory_p4 partition of public.pwj_inventory for values from (75) to (100);
grant usage on schema public to cycle_app;
grant select on public.products, public.pwj_orders, public.pwj_inventory to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.pwj_orders
select g, g % 100, ((g::bigint * 37) % 1000)::int from generate_series(1,120000) g;
insert into public.pwj_inventory
select g, g % 100, ((g::bigint * 17) % 250)::int from generate_series(1,120000) g;
analyze public.products;
analyze public.pwj_orders;
analyze public.pwj_inventory;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_partitionwise_join=%';"
}
probe() {
  local url="$1" setting plan digest row join_count
  setting="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_partitionwise_join;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) select count(*) from public.pwj_orders o join public.pwj_inventory i on i.bucket=o.bucket and i.id=o.id;" | tr '\n' ';')"
  digest="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "select md5(count(*)::text || ':' || coalesce(sum(o.amount+i.quantity),0)::text) from public.pwj_orders o join public.pwj_inventory i on i.bucket=o.bucket and i.id=o.id;")"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  join_count="$(grep -o 'Hash Join' <<<"$plan" | wc -l | tr -d ' ')"
  printf '%s|hash_joins=%s|%s|digest=%s|%s' "$setting" "$join_count" "$plan" "$digest" "$row"
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app partitionwise-join probe=%s\ndestination app partitionwise-join probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'enable_partitionwise_join=on' && "${dst_setting,,}" == 'enable_partitionwise_join=off' ]] || { echo 'Fixture did not establish enable_partitionwise_join drift.' >&2; exit 2; }
src_digest="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$src_probe")"; dst_digest="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$dst_probe")"
[[ -n "$src_digest" && "$src_digest" == "$dst_digest" ]] || { echo 'Join results diverged unexpectedly.' >&2; exit 2; }
src_joins="$(sed -n 's/.*|hash_joins=\([0-9]*\)|.*/\1/p' <<<"$src_probe")"; dst_joins="$(sed -n 's/.*|hash_joins=\([0-9]*\)|.*/\1/p' <<<"$dst_probe")"
[[ "$src_probe" == on\|*"Append"*"Hash Join"*"pwj_orders_p1"*"pwj_inventory_p1"*"pwj_orders_p4"*"pwj_inventory_p4"*"|digest="*"|15000|SOURCE-SKU-15000|0" && "$src_joins" -ge 4 ]] || { echo "Source did not choose partitionwise join: $src_probe" >&2; exit 2; }
[[ "$dst_probe" == off\|*"Hash Join"*"Append"*"pwj_orders_p1"*"pwj_orders_p4"*"Append"*"pwj_inventory_p1"*"pwj_inventory_p4"*"|digest="*"|15000|SOURCE-SKU-15000|0" && "$dst_joins" -lt "$src_joins" ]] || { echo "Destination did not choose non-partitionwise join: $dst_probe" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.pwj_orders,public.pwj_orders_p1,public.pwj_orders_p2,public.pwj_orders_p3,public.pwj_orders_p4,public.pwj_inventory,public.pwj_inventory_p1,public.pwj_inventory_p2,public.pwj_inventory_p3,public.pwj_inventory_p4' bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_PARTITIONWISE_JOIN_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'enable_partitionwise_join|pg_db_role_setting|role setting' <<<"$out"; then echo 'NEON_ROLE_ENABLE_PARTITIONWISE_JOIN_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_ROLE_ENABLE_PARTITIONWISE_JOIN_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app partitionwise-join probe=%s\ndestination app partitionwise-join probe=%s\nNEON_ROLE_ENABLE_PARTITIONWISE_JOIN_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'enable_partitionwise_join=off' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
[[ "$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$src_after")" == "$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$dst_after")" ]] || { echo 'Post-sync join results diverged.' >&2; exit 2; }
[[ "$(sed -n 's/.*|hash_joins=\([0-9]*\)|.*/\1/p' <<<"$src_after")" -gt "$(sed -n 's/.*|hash_joins=\([0-9]*\)|.*/\1/p' <<<"$dst_after")" ]] || { echo 'Partitionwise join plan difference did not persist.' >&2; exit 2; }
echo 'NEON_ROLE_ENABLE_PARTITIONWISE_JOIN_DRIFT_DETECTED=false'
exit 1

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
alter role cycle_app set enable_partitionwise_aggregate = on;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_source;
SQL
psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set enable_partitionwise_aggregate = off;
alter role cycle_app set max_parallel_workers_per_gather = 0;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
create table public.partitionwise_aggregate_probe (
  id integer not null,
  bucket integer not null,
  amount integer not null
) partition by range (bucket);
create table public.pwa_p1 partition of public.partitionwise_aggregate_probe for values from (0) to (25);
create table public.pwa_p2 partition of public.partitionwise_aggregate_probe for values from (25) to (50);
create table public.pwa_p3 partition of public.partitionwise_aggregate_probe for values from (50) to (75);
create table public.pwa_p4 partition of public.partitionwise_aggregate_probe for values from (75) to (100);
grant usage on schema public to cycle_app;
grant select on public.products, public.partitionwise_aggregate_probe to cycle_app;
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100 from generate_series(1,20000) g;
insert into public.partitionwise_aggregate_probe
select g, g % 100, ((g::bigint * 37) % 1000)::int from generate_series(1,200000) g;
analyze public.products;
analyze public.partitionwise_aggregate_probe;
SQL
done
psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11); analyze public.products;"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'enable_partitionwise_aggregate=%';"
}
probe() {
  local url="$1" setting plan digest row agg_count
  setting="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c 'show enable_partitionwise_aggregate;')"
  plan="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off) select bucket,sum(amount) from public.partitionwise_aggregate_probe group by bucket order by bucket;" | tr '\n' ';')"
  digest="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -c "select md5(string_agg(bucket||':'||total,',' order by bucket)) from (select bucket,sum(amount)::text total from public.partitionwise_aggregate_probe group by bucket) s;")"
  row="$(psql "$url" -X -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=15000;')"
  agg_count="$(grep -o 'Aggregate' <<<"$plan" | wc -l | tr -d ' ')"
  printf '%s|agg_nodes=%s|%s|digest=%s|%s' "$setting" "$agg_count" "$plan" "$digest" "$row"
}

src_setting="$(role_setting "$SRC_ADMIN")"; dst_setting="$(role_setting "$DST_ADMIN")"
src_probe="$(probe "$SRC_APP")"; dst_probe="$(probe "$DST_APP")"
printf 'BEFORE\nsource role setting=%s\ndestination role setting=%s\nsource app partitionwise-aggregate probe=%s\ndestination app partitionwise-aggregate probe=%s\n' "$src_setting" "$dst_setting" "$src_probe" "$dst_probe"
[[ "${src_setting,,}" == 'enable_partitionwise_aggregate=on' && "${dst_setting,,}" == 'enable_partitionwise_aggregate=off' ]] || { echo 'Fixture did not establish enable_partitionwise_aggregate drift.' >&2; exit 2; }
src_digest="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$src_probe")"; dst_digest="$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$dst_probe")"
[[ -n "$src_digest" && "$src_digest" == "$dst_digest" ]] || { echo 'Aggregate results diverged unexpectedly.' >&2; exit 2; }
src_nodes="$(sed -n 's/.*|agg_nodes=\([0-9]*\)|.*/\1/p' <<<"$src_probe")"; dst_nodes="$(sed -n 's/.*|agg_nodes=\([0-9]*\)|.*/\1/p' <<<"$dst_probe")"
[[ "$src_probe" == on\|*"Append"*"Aggregate"*"pwa_p1"*"pwa_p4"*"|digest="*"|15000|SOURCE-SKU-15000|0" && "$src_nodes" -ge 4 ]] || { echo "Source did not choose partitionwise aggregation: $src_probe" >&2; exit 2; }
[[ "$dst_probe" == off\|*"Aggregate"*"Append"*"pwa_p1"*"pwa_p4"*"|digest="*"|15000|SOURCE-SKU-15000|0" && "$dst_nodes" -lt "$src_nodes" ]] || { echo "Destination did not choose non-partitionwise aggregation: $dst_probe" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.partitionwise_aggregate_probe,public.pwa_p1,public.pwa_p2,public.pwa_p3,public.pwa_p4' bash scripts/neon-sync/append-sync.sh 2>&1)"; rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_ENABLE_PARTITIONWISE_AGGREGATE_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'enable_partitionwise_aggregate|pg_db_role_setting|role setting' <<<"$out"; then echo 'NEON_ROLE_ENABLE_PARTITIONWISE_AGGREGATE_DRIFT_FAIL_CLOSED=true'; exit 0; fi
  echo 'NEON_ROLE_ENABLE_PARTITIONWISE_AGGREGATE_DRIFT_FAIL_CLOSED=false'; exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_after="$(probe "$SRC_APP")"; dst_after="$(probe "$DST_APP")"
printf 'AFTER\ndestination role setting=%s\nappended source row=%s\nsource app partitionwise-aggregate probe=%s\ndestination app partitionwise-aggregate probe=%s\nNEON_ROLE_ENABLE_PARTITIONWISE_AGGREGATE_DRIFT_SYNC_EXIT=%s\n' "$dst_setting_after" "$dst_row" "$src_after" "$dst_after" "$rc"
[[ "${dst_setting_after,,}" == 'enable_partitionwise_aggregate=off' ]] || { echo 'Destination setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
[[ "$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$src_after")" == "$(sed -n 's/.*|digest=\([^|]*\)|.*/\1/p' <<<"$dst_after")" ]] || { echo 'Post-sync aggregate results diverged.' >&2; exit 2; }
[[ "$(sed -n 's/.*|agg_nodes=\([0-9]*\)|.*/\1/p' <<<"$src_after")" -gt "$(sed -n 's/.*|agg_nodes=\([0-9]*\)|.*/\1/p' <<<"$dst_after")" ]] || { echo 'Partitionwise plan difference did not persist.' >&2; exit 2; }
echo 'NEON_ROLE_ENABLE_PARTITIONWISE_AGGREGATE_DRIFT_DETECTED=false'
exit 1

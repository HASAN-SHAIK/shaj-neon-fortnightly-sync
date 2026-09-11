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
alter role cycle_app set geqo = off;
alter role cycle_app set geqo_threshold = 2;
alter role cycle_app set join_collapse_limit = 12;
create database cycle_d_source;
SQL

psql "$DST_ROOT" -v ON_ERROR_STOP=1 <<'SQL'
create role cycle_app login;
alter role cycle_app set geqo = on;
alter role cycle_app set geqo_threshold = 2;
alter role cycle_app set geqo_seed = 0.73;
alter role cycle_app set join_collapse_limit = 12;
create database cycle_d_destination;
SQL

for url in "$SRC_ADMIN" "$DST_ADMIN"; do
  psql "$url" -v ON_ERROR_STOP=1 <<'SQL'
create table public.products (id bigint primary key, sku text not null, quantity integer not null);
insert into public.products
select g, 'SOURCE-SKU-' || lpad(g::text,5,'0'), g % 100
from generate_series(1,20000) g;

create table public.geqo_a (id integer primary key, k integer not null, payload text not null);
create table public.geqo_b (id integer primary key, k integer not null, payload text not null);
create table public.geqo_c (id integer primary key, k integer not null, payload text not null);
create table public.geqo_d (id integer primary key, k integer not null, payload text not null);
create table public.geqo_e (id integer primary key, k integer not null, payload text not null);
create table public.geqo_f (id integer primary key, k integer not null, payload text not null);

insert into public.geqo_a select g, g % 97, repeat('a',16) from generate_series(1,25000) g;
insert into public.geqo_b select g, g % 97, repeat('b',16) from generate_series(1,8000) g;
insert into public.geqo_c select g, g % 97, repeat('c',16) from generate_series(1,4000) g;
insert into public.geqo_d select g, g % 97, repeat('d',16) from generate_series(1,2000) g;
insert into public.geqo_e select g, g % 97, repeat('e',16) from generate_series(1,1000) g;
insert into public.geqo_f select g, g % 97, repeat('f',16) from generate_series(1,500) g;

create index geqo_a_k_idx on public.geqo_a(k);
create index geqo_b_k_idx on public.geqo_b(k);
create index geqo_c_k_idx on public.geqo_c(k);
create index geqo_d_k_idx on public.geqo_d(k);
create index geqo_e_k_idx on public.geqo_e(k);
create index geqo_f_k_idx on public.geqo_f(k);

analyze public.geqo_a; analyze public.geqo_b; analyze public.geqo_c;
analyze public.geqo_d; analyze public.geqo_e; analyze public.geqo_f;

grant usage on schema public to cycle_app;
grant select on public.products, public.geqo_a, public.geqo_b, public.geqo_c, public.geqo_d, public.geqo_e, public.geqo_f to cycle_app;
SQL
done

psql "$SRC_ADMIN" -v ON_ERROR_STOP=1 -c "insert into public.products values (20001,'SOURCE-SKU-20001',11);"

role_setting() {
  psql "$1" -v ON_ERROR_STOP=1 -At -c "select cfg from pg_db_role_setting s join pg_roles r on r.oid=s.setrole cross join lateral unnest(s.setconfig) cfg where r.rolname='cycle_app' and s.setdatabase=0 and lower(cfg) like 'geqo=%';"
}

effective_geqo() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -c 'show geqo;'
}

query_sql="select count(*) from public.geqo_a a join public.geqo_b b on b.k=a.k join public.geqo_c c on c.k=b.k join public.geqo_d d on d.k=c.k join public.geqo_e e on e.k=d.k join public.geqo_f f on f.k=e.k where a.id <= 120 and f.id <= 120;"

plan() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -c "explain (costs off, summary off) $query_sql"
}

result_count() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -c "$query_sql"
}

ordinary_row() {
  psql "$1" -X -v ON_ERROR_STOP=1 -At -F '|' -c "select id,sku,quantity from public.products where id=15000;"
}

src_setting="$(role_setting "$SRC_ADMIN")"
dst_setting="$(role_setting "$DST_ADMIN")"
src_effective="$(effective_geqo "$SRC_APP")"
dst_effective="$(effective_geqo "$DST_APP")"
src_plan="$(plan "$SRC_APP")"
dst_plan="$(plan "$DST_APP")"
src_count="$(result_count "$SRC_APP")"
dst_count="$(result_count "$DST_APP")"
src_row="$(ordinary_row "$SRC_APP")"
dst_row="$(ordinary_row "$DST_APP")"

printf 'BEFORE\nsource catalog setting=%s\ndestination catalog setting=%s\nsource effective geqo=%s\ndestination effective geqo=%s\nsource plan:\n%s\ndestination plan:\n%s\nsource result=%s\ndestination result=%s\nsource ordinary row=%s\ndestination ordinary row=%s\n' \
  "$src_setting" "$dst_setting" "$src_effective" "$dst_effective" "$src_plan" "$dst_plan" "$src_count" "$dst_count" "$src_row" "$dst_row"

[[ "${src_setting,,}" == 'geqo=off' && "${dst_setting,,}" == 'geqo=on' ]] || { echo 'Fixture did not establish GEQO role drift.' >&2; exit 2; }
[[ "${src_effective,,}" == 'off' && "${dst_effective,,}" == 'on' ]] || { echo 'Effective GEQO drift not established.' >&2; exit 2; }
[[ "$src_row" == '15000|SOURCE-SKU-15000|0' && "$dst_row" == "$src_row" ]] || { echo 'Ordinary application baseline mismatch.' >&2; exit 2; }
[[ "$src_count" == "$dst_count" && "$src_count" =~ ^[0-9]+$ ]] || { echo "Join result mismatch: source=$src_count destination=$dst_count" >&2; exit 2; }

set +e
out="$(SOURCE_DATABASE_URL="$SRC_ADMIN" DESTINATION_DATABASE_URL="$DST_ADMIN" EXCLUDED_TABLES='public.geqo_a,public.geqo_b,public.geqo_c,public.geqo_d,public.geqo_e,public.geqo_f' bash scripts/neon-sync/append-sync.sh 2>&1)"
rc=$?
set -e
printf '%s\n' "$out"

if [[ "$rc" -ne 0 ]]; then
  printf 'NEON_ROLE_GEQO_DRIFT_SYNC_EXIT=%s\n' "$rc"
  if grep -Eqi 'geqo|pg_db_role_setting|role setting' <<<"$out"; then
    echo 'NEON_ROLE_GEQO_DRIFT_FAIL_CLOSED=true'
    exit 0
  fi
  echo 'NEON_ROLE_GEQO_DRIFT_FAIL_CLOSED=false'
  exit 1
fi

dst_setting_after="$(role_setting "$DST_ADMIN")"
dst_effective_after="$(effective_geqo "$DST_APP")"
dst_synced_row="$(psql "$DST_ADMIN" -v ON_ERROR_STOP=1 -At -F '|' -c 'select id,sku,quantity from public.products where id=20001;')"
src_plan_after="$(plan "$SRC_APP")"
dst_plan_after="$(plan "$DST_APP")"
src_count_after="$(result_count "$SRC_APP")"
dst_count_after="$(result_count "$DST_APP")"

printf 'AFTER\ndestination catalog setting=%s\ndestination effective geqo=%s\nappended source row=%s\nsource plan:\n%s\ndestination plan:\n%s\nsource result=%s\ndestination result=%s\nNEON_ROLE_GEQO_DRIFT_SYNC_EXIT=%s\n' \
  "$dst_setting_after" "$dst_effective_after" "$dst_synced_row" "$src_plan_after" "$dst_plan_after" "$src_count_after" "$dst_count_after" "$rc"

[[ "${dst_setting_after,,}" == 'geqo=on' && "${dst_effective_after,,}" == 'on' ]] || { echo 'Destination GEQO setting changed unexpectedly.' >&2; exit 2; }
[[ "$dst_synced_row" == '20001|SOURCE-SKU-20001|11' ]] || { echo 'Legitimate application row did not synchronize.' >&2; exit 2; }
[[ "$src_count_after" == "$dst_count_after" && "$src_count_after" == "$src_count" ]] || { echo 'Join result changed unexpectedly after sync.' >&2; exit 2; }

echo 'NEON_ROLE_GEQO_DRIFT_DETECTED=false'
if [[ "$src_plan_after" != "$dst_plan_after" ]]; then
  echo 'NEON_ROLE_GEQO_PLAN_DIVERGENCE=true'
  exit 1
fi

echo 'NEON_ROLE_GEQO_PLAN_DIVERGENCE=false'
exit 3

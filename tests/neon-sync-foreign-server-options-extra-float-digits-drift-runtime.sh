#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/18/bin:$PATH"
S='postgresql://postgres@127.0.0.1:55432/cycle_d_source'; D='postgresql://postgres@127.0.0.1:55433/cycle_d_destination'
SR='postgresql://postgres@127.0.0.1:55432/postgres'; DR='postgresql://postgres@127.0.0.1:55433/postgres'
SA='postgresql://cycle_app@127.0.0.1:55432/cycle_d_source'; DA='postgresql://cycle_app@127.0.0.1:55433/cycle_d_destination'
for r in "$SR" "$DR"; do psql "$r" -v ON_ERROR_STOP=1 -c 'create role cycle_app login;'; done
psql "$SR" -v ON_ERROR_STOP=1 -c 'create database cycle_d_source;'; psql "$DR" -v ON_ERROR_STOP=1 -c 'create database cycle_d_destination;'
setup(){ local u="$1" db="$2" efd="$3"; psql "$u" -v ON_ERROR_STOP=1 -v db="$db" -v efd="$efd" <<'SQL'
create extension postgres_fdw; create table products(id bigint primary key,sku text not null,quantity int not null); create table remote_products(id bigint primary key,sku text not null,quantity int not null); insert into remote_products values(1,'REMOTE-SKU-1',7); create view remote_policy as select current_setting('extra_float_digits')::text as extra_float_digits; grant usage on schema public to cycle_app; grant select on remote_products,remote_policy to cycle_app;
select format('create server retail_loopback foreign data wrapper postgres_fdw options(host ''127.0.0.1'',port ''5432'',dbname %L,options %L)',:'db','-c extra_float_digits=' || :'efd') \gexec
create user mapping for cycle_app server retail_loopback options(user 'cycle_app',password_required 'false'); create user mapping for postgres server retail_loopback options(user 'postgres',password_required 'false'); create foreign table products_remote(id bigint,sku text,quantity int) server retail_loopback options(schema_name 'public',table_name 'remote_products'); create foreign table policy_remote(extra_float_digits text) server retail_loopback options(schema_name 'public',table_name 'remote_policy'); grant select on products_remote,policy_remote to cycle_app;
SQL
}
setup "$S" cycle_d_source 3; setup "$D" cycle_d_destination 0
psql "$S" -c "insert into products values(1,'BASE-SKU-1',7)"; psql "$D" -c "insert into products values(1,'BASE-SKU-1',7)"
opt(){ psql "$1" -Atc "select option_value from pg_options_to_table((select srvoptions from pg_foreign_server where srvname='retail_loopback')) where option_name='options';"; }
sb=$(opt "$S"); db=$(opt "$D"); sr=$(psql "$SA" -At -F '|' -c 'select id,sku,quantity from products_remote'); dr=$(psql "$DA" -At -F '|' -c 'select id,sku,quantity from products_remote'); se=$(psql "$SA" -Atc 'select extra_float_digits from policy_remote'); de=$(psql "$DA" -Atc 'select extra_float_digits from policy_remote'); printf 'BEFORE source=%s destination=%s source_app=%s destination_app=%s source_extra_float_digits=%s destination_extra_float_digits=%s\n' "$sb" "$db" "$sr" "$dr" "$se" "$de"
[[ "$sb" == '-c extra_float_digits=3' && "$db" == '-c extra_float_digits=0' && "$sr" == '1|REMOTE-SKU-1|7' && "$dr" == '1|REMOTE-SKU-1|7' && "$se" == '3' && "$de" == '0' ]] || { echo 'Fixture invalid'; exit 2; }
psql "$S" -c "insert into products values(2,'SOURCE-SKU-2',11)"
set +e; out=$(SOURCE_DATABASE_URL="$S" DESTINATION_DATABASE_URL="$D" bash scripts/neon-sync/append-sync.sh 2>&1); ec=$?; set -e; printf '%s\n' "$out"
if [[ $ec -ne 0 ]]; then echo "NEON_FOREIGN_SERVER_OPTIONS_EXTRA_FLOAT_DIGITS_DRIFT_SYNC_EXIT=$ec"; if grep -Eqi 'extra_float_digits|foreign server.*(drift|mismatch|option)' <<<"$out"; then echo 'NEON_FOREIGN_SERVER_OPTIONS_EXTRA_FLOAT_DIGITS_DRIFT_FAIL_CLOSED=true'; exit 0; fi; exit 1; fi
da=$(opt "$D"); row=$(psql "$D" -At -F '|' -c 'select id,sku,quantity from products where id=2'); de2=$(psql "$DA" -Atc 'select extra_float_digits from policy_remote'); printf 'AFTER destination=%s row=%s destination_extra_float_digits=%s\nNEON_FOREIGN_SERVER_OPTIONS_EXTRA_FLOAT_DIGITS_DRIFT_SYNC_EXIT=%s\n' "$da" "$row" "$de2" "$ec"
if [[ "$da" == '-c extra_float_digits=3' && "$row" == '2|SOURCE-SKU-2|11' && "$de2" == '3' ]]; then echo 'NEON_FOREIGN_SERVER_OPTIONS_EXTRA_FLOAT_DIGITS_DRIFT_DETECTED=true'; exit 0; fi
if [[ "$da" == '-c extra_float_digits=0' && "$row" == '2|SOURCE-SKU-2|11' && "$de2" == '0' ]]; then echo 'NEON_FOREIGN_SERVER_OPTIONS_EXTRA_FLOAT_DIGITS_DRIFT_DETECTED=false'; echo 'NEON_FOREIGN_SERVER_OPTIONS_EXTRA_FLOAT_DIGITS_POLICY_DIVERGENCE=true'; exit 1; fi
exit 2

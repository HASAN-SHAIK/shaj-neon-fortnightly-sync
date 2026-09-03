#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -d "/usr/lib/postgresql/17/bin" ]]; then
  export PATH="/usr/lib/postgresql/17/bin:$PATH"
fi

validate_database_url() {
  local name="$1"
  local value="$2"

  if [[ "$value" == psql* ]]; then
    echo "$name must be only the postgresql:// connection URL, not a full psql command." >&2
    exit 2
  fi

  if [[ "$value" == *\\_* ]] || [[ "$value" == *\\@* ]]; then
    echo "$name contains backslash escapes. Paste the raw Neon URL without Markdown escaping." >&2
    exit 2
  fi

  if [[ "$value" != postgresql://* && "$value" != postgres://* ]]; then
    echo "$name must start with postgresql:// or postgres://." >&2
    exit 2
  fi
}

build_pair_file() {
  local pair_file="$1"

  if [[ -n "${NEON_DATABASE_PAIRS_JSON:-}" ]]; then
    node - "$pair_file" <<'NODE'
const fs = require('fs');

const outputPath = process.argv[2];
let pairs;

try {
  pairs = JSON.parse(process.env.NEON_DATABASE_PAIRS_JSON || '');
} catch (error) {
  console.error(`NEON_DATABASE_PAIRS_JSON is not valid JSON: ${error.message}`);
  process.exit(2);
}

if (!Array.isArray(pairs) || pairs.length === 0) {
  console.error('NEON_DATABASE_PAIRS_JSON must be a non-empty JSON array.');
  process.exit(2);
}

const rows = pairs.map((pair, index) => {
  const label = String(pair.label || `database_${index + 1}`);
  const source = pair.source || pair.sourceUrl;
  const destination = pair.destination || pair.destinationUrl;
  const excludedTables = Array.isArray(pair.excludedTables)
    ? pair.excludedTables.join(',')
    : String(pair.excludedTables || '');

  if (!source || !destination) {
    console.error(`Pair ${label} must include source and destination URLs.`);
    process.exit(2);
  }

  return [label, source, destination, excludedTables]
    .map((value) => String(value).replace(/\t/g, ' '))
    .join('\t');
});

fs.writeFileSync(outputPath, rows.join('\n') + '\n');
NODE
    return
  fi

  if [[ -n "${SOURCE_MASTER_DATABASE_URL:-}" || -n "${DESTINATION_MASTER_DATABASE_URL:-}" ]]; then
    if [[ -z "${SOURCE_MASTER_DATABASE_URL:-}" ]]; then
      echo "SOURCE_MASTER_DATABASE_URL secret is missing." >&2
      exit 1
    fi

    if [[ -z "${DESTINATION_MASTER_DATABASE_URL:-}" ]]; then
      echo "DESTINATION_MASTER_DATABASE_URL secret is missing." >&2
      exit 1
    fi

    validate_database_url "SOURCE_MASTER_DATABASE_URL" "$SOURCE_MASTER_DATABASE_URL"
    validate_database_url "DESTINATION_MASTER_DATABASE_URL" "$DESTINATION_MASTER_DATABASE_URL"

    local tenant_file
    tenant_file="$(mktemp)"

    local tenant_query="${TENANT_DATABASE_QUERY:-select distinct database_name from public.tenants where database_name is not null and btrim(database_name) <> '' order by database_name;}"

    echo "Discovering tenant databases from source master database..."
    psql "$SOURCE_MASTER_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "$tenant_query" > "$tenant_file"

    node - "$pair_file" "$tenant_file" <<'NODE'
const fs = require('fs');

const [outputPath, tenantPath] = process.argv.slice(2);

function setDatabaseName(rawUrl, databaseName) {
  const url = new URL(rawUrl);
  url.pathname = `/${databaseName}`;
  return url.toString();
}

const sourceMaster = process.env.SOURCE_MASTER_DATABASE_URL;
const destinationMaster = process.env.DESTINATION_MASTER_DATABASE_URL;
const tenantNames = fs.readFileSync(tenantPath, 'utf8')
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean);

const rows = [
  ['masterdb', sourceMaster, destinationMaster, ''],
  ...tenantNames.map((databaseName) => [
    databaseName,
    setDatabaseName(sourceMaster, databaseName),
    setDatabaseName(destinationMaster, databaseName),
    '',
  ]),
];

fs.writeFileSync(
  outputPath,
  rows.map((row) => row.map((value) => String(value).replace(/\t/g, ' ')).join('\t')).join('\n') + '\n',
);

console.log(`Configured database pairs: ${rows.length}`);
console.log(`Discovered tenant databases: ${tenantNames.length}`);
NODE

    rm -f "$tenant_file"
    return
  fi

  if [[ -z "${SOURCE_DATABASE_URL:-}" ]]; then
    echo "SOURCE_DATABASE_URL secret is missing." >&2
    exit 1
  fi

  if [[ -z "${DESTINATION_DATABASE_URL:-}" ]]; then
    echo "DESTINATION_DATABASE_URL secret is missing." >&2
    exit 1
  fi

  printf 'default\t%s\t%s\t%s\n' "$SOURCE_DATABASE_URL" "$DESTINATION_DATABASE_URL" "${EXCLUDED_TABLES:-}" > "$pair_file"
}

sync_pair() {
  local label="$1"
  local source_url="$2"
  local destination_url="$3"
  local excluded_tables="$4"

  echo "::group::Sync $label"

  validate_database_url "$label source" "$source_url"
  validate_database_url "$label destination" "$destination_url"

  local workdir
  workdir="$(mktemp -d)"

  local schema_file="$workdir/source-schema.sql"
  local copy_file="$workdir/source-data.sql"
  local source_columns="$workdir/source-columns.tsv"
  local destination_columns="$workdir/destination-columns.tsv"
  local missing_columns_sql="$workdir/add-missing-columns.sql"

  echo "Checking source connection for $label..."
  psql "$source_url" -v ON_ERROR_STOP=1 -Atc "select current_database();"

  echo "Checking destination connection for $label..."
  psql "$destination_url" -v ON_ERROR_STOP=1 -Atc "select current_database();"

  echo "Dumping source schema for $label..."
  pg_dump --schema-only --no-owner --no-privileges "$source_url" > "$schema_file"

  echo "Creating any missing schema objects on destination for $label..."
  psql "$destination_url" -v ON_ERROR_STOP=0 -f "$schema_file"

  local column_query="
select
  n.nspname as table_schema,
  c.relname as table_name,
  a.attname as column_name,
  a.attnum as ordinal_position,
  pg_catalog.format_type(a.atttypid, a.atttypmod) as column_type,
  pg_get_expr(ad.adbin, ad.adrelid) as column_default,
  a.attidentity as identity_kind,
  a.attgenerated as generated_kind
from pg_catalog.pg_attribute a
join pg_catalog.pg_class c on c.oid = a.attrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
left join pg_catalog.pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
where a.attnum > 0
  and not a.attisdropped
  and c.relkind in ('r', 'p')
  and n.nspname not in ('pg_catalog', 'information_schema')
order by n.nspname, c.relname, a.attnum;
"

  psql "$source_url" -v ON_ERROR_STOP=1 -At -F $'\t' -c "$column_query" > "$source_columns"
  psql "$destination_url" -v ON_ERROR_STOP=1 -At -F $'\t' -c "$column_query" > "$destination_columns"

  node - "$source_columns" "$destination_columns" "$missing_columns_sql" <<'NODE'
const fs = require('fs');

const [sourcePath, destinationPath, outputPath] = process.argv.slice(2);

function readRows(path) {
  const text = fs.readFileSync(path, 'utf8').trim();
  if (!text) return [];
  return text.split(/\r?\n/).map((line) => {
    const [
      table_schema,
      table_name,
      column_name,
      ordinal_position,
      column_type,
      column_default,
      identity_kind,
      generated_kind,
    ] = line.split('\t');
    return {
      table_schema,
      table_name,
      column_name,
      ordinal_position: Number(ordinal_position),
      column_type,
      column_default,
      identity_kind,
      generated_kind,
    };
  });
}

function ident(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

const sourceRows = readRows(sourcePath);
const destinationRows = readRows(destinationPath);
const destinationKeys = new Set(
  destinationRows.map((row) => `${row.table_schema}.${row.table_name}.${row.column_name}`),
);

const statements = [];
for (const row of sourceRows) {
  const key = `${row.table_schema}.${row.table_name}.${row.column_name}`;
  if (destinationKeys.has(key)) continue;

  const parts = [
    `alter table ${ident(row.table_schema)}.${ident(row.table_name)}`,
    `add column if not exists ${ident(row.column_name)}`,
    row.column_type,
  ];

  if (row.identity_kind === 'a') {
    parts.push('generated always as identity');
  } else if (row.identity_kind === 'd') {
    parts.push('generated by default as identity');
  } else if (row.generated_kind) {
    continue;
  } else if (row.column_default) {
    parts.push(`default ${row.column_default}`);
  }

  statements.push(`${parts.join(' ')};`);
}

fs.writeFileSync(outputPath, statements.join('\n') + (statements.length ? '\n' : ''));
console.log(`Missing columns to add: ${statements.length}`);
NODE

  if [[ -s "$missing_columns_sql" ]]; then
    echo "Adding missing destination columns for $label..."
    psql "$destination_url" -v ON_ERROR_STOP=1 -f "$missing_columns_sql"
  else
    echo "No missing destination columns found for $label."
  fi

  local exclude_args=()
  if [[ -n "$excluded_tables" ]]; then
    IFS=',' read -ra excluded <<< "$excluded_tables"
    for table_name in "${excluded[@]}"; do
      local trimmed
      trimmed="$(echo "$table_name" | xargs)"
      if [[ -n "$trimmed" ]]; then
        exclude_args+=(--exclude-table-data="$trimmed")
      fi
    done
  fi

  echo "Dumping source data as insert statements for $label..."
  pg_dump \
    --data-only \
    --inserts \
    --on-conflict-do-nothing \
    --no-owner \
    --no-privileges \
    "${exclude_args[@]}" \
    "$source_url" \
    > "$copy_file"

  echo "Appending data into destination for $label..."
  psql "$destination_url" -v ON_ERROR_STOP=1 -f "$copy_file"

  rm -rf "$workdir"
  echo "Append sync completed successfully for $label."
  echo "::endgroup::"
}

ensure_destination_database() {
  local admin_url="$1"
  local database_name="$2"

  local create_database_sql="
select format('create database %I', :'database_name')
where not exists (
  select 1 from pg_database where datname = :'database_name'
);
"

  echo "Ensuring destination database exists for $database_name..."
  psql "$admin_url" -v ON_ERROR_STOP=1 -v database_name="$database_name" -Atc "$create_database_sql" | psql "$admin_url" -v ON_ERROR_STOP=1
}

pair_file="$(mktemp)"
trap 'rm -f "$pair_file"' EXIT
build_pair_file "$pair_file"

while IFS=$'\t' read -r label source_url destination_url excluded_tables; do
  [[ -z "${label:-}" ]] && continue
  if [[ -n "${DESTINATION_MASTER_DATABASE_URL:-}" && "$label" != "masterdb" ]]; then
    ensure_destination_database "$DESTINATION_MASTER_DATABASE_URL" "$label"
  fi
  sync_pair "$label" "$source_url" "$destination_url" "${excluded_tables:-}"
done < "$pair_file"

echo "All configured Neon database syncs completed successfully."

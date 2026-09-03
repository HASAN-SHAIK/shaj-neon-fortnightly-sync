#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -d "/usr/lib/postgresql/18/bin" ]]; then
  export PATH="/usr/lib/postgresql/18/bin:$PATH"
elif [[ -d "/usr/lib/postgresql/17/bin" ]]; then
  export PATH="/usr/lib/postgresql/17/bin:$PATH"
fi

RUN_FAILED=0
FAILURE_REASON=""
ROLLBACK_ATTEMPTED=0
ROLLBACK_SUCCEEDED=0
STATUS_FILE="$(mktemp)"

send_failure_email() {
  local subject="$1"
  local body="$2"

  if [[ -z "${NOTIFY_EMAIL_TO:-}" || -z "${SMTP_HOST:-}" || -z "${SMTP_USERNAME:-}" || -z "${SMTP_PASSWORD:-}" ]]; then
    echo "Failure email skipped: configure NOTIFY_EMAIL_TO, SMTP_HOST, SMTP_USERNAME, and SMTP_PASSWORD."
    return
  fi

  local smtp_port="${SMTP_PORT:-587}"
  local from="${NOTIFY_EMAIL_FROM:-$SMTP_USERNAME}"
  local config_file
  local message_file

  config_file="$(mktemp)"
  message_file="$(mktemp)"

  {
    printf '%s\n' 'defaults'
    printf '%s\n' 'auth on'
    printf '%s\n' 'tls on'
    printf '%s\n' 'tls_trust_file /etc/ssl/certs/ca-certificates.crt'
    printf 'host %s\n' "$SMTP_HOST"
    printf 'port %s\n' "$smtp_port"
    printf 'user %s\n' "$SMTP_USERNAME"
    printf 'password %s\n' "$SMTP_PASSWORD"
    printf 'from %s\n' "$from"
  } > "$config_file"
  chmod 600 "$config_file"

  {
    printf 'From: %s\n' "$from"
    printf 'To: %s\n' "$NOTIFY_EMAIL_TO"
    printf 'Subject: %s\n' "$subject"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf '\n'
    printf '%s\n' "$body"
  } > "$message_file"

  msmtp --file="$config_file" --read-envelope-from -- "$NOTIFY_EMAIL_TO" < "$message_file" || true
  rm -f "$config_file" "$message_file"
}

handle_failure() {
  local line="$1"
  local code="$2"

  RUN_FAILED=1
  FAILURE_REASON="Workflow failed at line $line with exit code $code."
  if [[ -f "$STATUS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATUS_FILE" || true
  fi
  echo "$FAILURE_REASON" >&2

  send_failure_email \
    "SHAJ Neon sync failed" \
    "The SHAJ Neon sync workflow failed.

Reason: $FAILURE_REASON
Direction: ${SELECTED_SYNC_DIRECTION:-unknown}
Rollback attempted: $ROLLBACK_ATTEMPTED
Rollback succeeded: $ROLLBACK_SUCCEEDED

Open the GitHub Actions run for full logs."

  exit "$code"
}

trap 'handle_failure $LINENO $?' ERR

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

configure_alternating_master_urls() {
  if [[ -z "${PRIMARY_MASTER_DATABASE_URL:-}" && -z "${MIRROR_MASTER_DATABASE_URL:-}" ]]; then
    return
  fi

  if [[ -z "${PRIMARY_MASTER_DATABASE_URL:-}" ]]; then
    echo "PRIMARY_MASTER_DATABASE_URL secret is missing." >&2
    exit 1
  fi

  if [[ -z "${MIRROR_MASTER_DATABASE_URL:-}" ]]; then
    echo "MIRROR_MASTER_DATABASE_URL secret is missing." >&2
    exit 1
  fi

  validate_database_url "PRIMARY_MASTER_DATABASE_URL" "$PRIMARY_MASTER_DATABASE_URL"
  validate_database_url "MIRROR_MASTER_DATABASE_URL" "$MIRROR_MASTER_DATABASE_URL"

  local direction="${SYNC_DIRECTION:-auto}"

  if [[ "$direction" == "auto" ]]; then
    local ist_day
    ist_day="$(TZ=Asia/Kolkata date +%-d)"

    if (( ist_day <= 15 )); then
      direction="primary-to-mirror"
    else
      direction="mirror-to-primary"
    fi
  fi

  case "$direction" in
    primary-to-mirror)
      export SOURCE_MASTER_DATABASE_URL="$PRIMARY_MASTER_DATABASE_URL"
      export DESTINATION_MASTER_DATABASE_URL="$MIRROR_MASTER_DATABASE_URL"
      export SELECTED_SYNC_DIRECTION="$direction"
      echo "Sync direction: primary to mirror."
      ;;
    mirror-to-primary)
      export SOURCE_MASTER_DATABASE_URL="$MIRROR_MASTER_DATABASE_URL"
      export DESTINATION_MASTER_DATABASE_URL="$PRIMARY_MASTER_DATABASE_URL"
      export SELECTED_SYNC_DIRECTION="$direction"
      echo "Sync direction: mirror to primary."
      ;;
    *)
      echo "SYNC_DIRECTION must be auto, primary-to-mirror, or mirror-to-primary." >&2
      exit 2
      ;;
  esac
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
  local wrapped_copy_file="$workdir/wrapped-source-data.sql"
  local source_columns="$workdir/source-columns.tsv"
  local destination_columns="$workdir/destination-columns.tsv"
  local missing_columns_sql="$workdir/add-missing-columns.sql"
  local disable_triggers_sql="$workdir/disable-user-triggers.sql"
  local enable_triggers_sql="$workdir/enable-user-triggers.sql"
  local verify_source_columns="$workdir/verify-source-columns.tsv"
  local verify_destination_columns="$workdir/verify-destination-columns.tsv"
  local verify_source_tables="$workdir/verify-source-tables.tsv"
  local verify_destination_tables="$workdir/verify-destination-tables.tsv"
  local row_count_sql="$workdir/row-counts.sql"
  local source_row_counts="$workdir/source-row-counts.tsv"
  local destination_row_counts="$workdir/destination-row-counts.tsv"

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
  psql "$destination_url" -v ON_ERROR_STOP=1 -Atc "
select format('alter table %I.%I disable trigger user;', schemaname, tablename)
from pg_catalog.pg_tables
where schemaname not in ('pg_catalog', 'information_schema')
order by schemaname, tablename;
" > "$disable_triggers_sql"

  psql "$destination_url" -v ON_ERROR_STOP=1 -Atc "
select format('alter table %I.%I enable trigger user;', schemaname, tablename)
from pg_catalog.pg_tables
where schemaname not in ('pg_catalog', 'information_schema')
order by schemaname, tablename;
" > "$enable_triggers_sql"

  {
    printf '%s\n' 'begin;'
    cat "$disable_triggers_sql"
    cat "$copy_file"
    cat "$enable_triggers_sql"
    printf '%s\n' 'commit;'
  } > "$wrapped_copy_file"

  psql "$destination_url" -v ON_ERROR_STOP=1 -f "$wrapped_copy_file"

  echo "Verifying schema and row counts for $label..."

  local table_query="
select n.nspname, c.relname
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'p')
  and n.nspname not in ('pg_catalog', 'information_schema')
order by n.nspname, c.relname;
"

  psql "$source_url" -v ON_ERROR_STOP=1 -At -F $'\t' -c "$column_query" > "$verify_source_columns"
  psql "$destination_url" -v ON_ERROR_STOP=1 -At -F $'\t' -c "$column_query" > "$verify_destination_columns"
  psql "$source_url" -v ON_ERROR_STOP=1 -At -F $'\t' -c "$table_query" > "$verify_source_tables"
  psql "$destination_url" -v ON_ERROR_STOP=1 -At -F $'\t' -c "$table_query" > "$verify_destination_tables"

  node - "$verify_source_columns" "$verify_destination_columns" "$verify_source_tables" "$verify_destination_tables" "$row_count_sql" "$excluded_tables" <<'NODE'
const fs = require('fs');

const [
  sourceColumnsPath,
  destinationColumnsPath,
  sourceTablesPath,
  destinationTablesPath,
  rowCountSqlPath,
  excludedTablesCsv = '',
] = process.argv.slice(2);

function readLines(path) {
  const text = fs.readFileSync(path, 'utf8').trim();
  return text ? text.split(/\r?\n/) : [];
}

function ident(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

const excludedTables = new Set(
  excludedTablesCsv.split(',').map((value) => value.trim()).filter(Boolean),
);

const sourceTables = readLines(sourceTablesPath).map((line) => {
  const [schema, table] = line.split('\t');
  return { schema, table, key: `${schema}.${table}` };
});
const destinationTables = new Set(
  readLines(destinationTablesPath).map((line) => line.split('\t').slice(0, 2).join('.')),
);

const schemaErrors = [];
for (const table of sourceTables) {
  if (!destinationTables.has(table.key)) {
    schemaErrors.push(`Missing destination table: ${table.key}`);
  }
}

function columnMap(path) {
  const map = new Map();
  for (const line of readLines(path)) {
    const [schema, table, column, , columnType] = line.split('\t');
    map.set(`${schema}.${table}.${column}`, columnType);
  }
  return map;
}

const sourceColumns = columnMap(sourceColumnsPath);
const destinationColumns = columnMap(destinationColumnsPath);
for (const [key, sourceType] of sourceColumns.entries()) {
  const destinationType = destinationColumns.get(key);
  if (!destinationType) {
    schemaErrors.push(`Missing destination column: ${key}`);
  } else if (destinationType !== sourceType) {
    schemaErrors.push(`Column type mismatch for ${key}: source=${sourceType}, destination=${destinationType}`);
  }
}

if (schemaErrors.length) {
  console.error('Schema verification failed:');
  for (const error of schemaErrors) console.error(`- ${error}`);
  process.exit(1);
}

const rowCountStatements = sourceTables
  .filter((table) => !excludedTables.has(table.key))
  .map((table) => {
    const label = table.key.replace(/'/g, "''");
    return `select '${label}' as table_name, count(*)::bigint as row_count from ${ident(table.schema)}.${ident(table.table)}`;
  });

fs.writeFileSync(rowCountSqlPath, rowCountStatements.join('\nunion all\n') + (rowCountStatements.length ? ';\n' : ''));
console.log(`Schema verification OK. Tables checked: ${sourceTables.length}. Row-count tables: ${rowCountStatements.length}.`);
NODE

  if [[ -s "$row_count_sql" ]]; then
    psql "$source_url" -v ON_ERROR_STOP=1 -At -F $'\t' -f "$row_count_sql" > "$source_row_counts"
    psql "$destination_url" -v ON_ERROR_STOP=1 -At -F $'\t' -f "$row_count_sql" > "$destination_row_counts"
  else
    : > "$source_row_counts"
    : > "$destination_row_counts"
  fi

  node - "$source_row_counts" "$destination_row_counts" <<'NODE'
const fs = require('fs');

const [sourcePath, destinationPath] = process.argv.slice(2);

function readCounts(path) {
  const text = fs.readFileSync(path, 'utf8').trim();
  const counts = new Map();
  if (!text) return counts;

  for (const line of text.split(/\r?\n/)) {
    const [tableName, rowCount] = line.split('\t');
    counts.set(tableName, BigInt(rowCount));
  }

  return counts;
}

const sourceCounts = readCounts(sourcePath);
const destinationCounts = readCounts(destinationPath);
const errors = [];

for (const [tableName, sourceCount] of sourceCounts.entries()) {
  const destinationCount = destinationCounts.get(tableName);
  if (destinationCount === undefined) {
    errors.push(`Missing destination row count for ${tableName}`);
  } else if (destinationCount < sourceCount) {
    errors.push(`${tableName}: source=${sourceCount}, destination=${destinationCount}`);
  }
}

if (errors.length) {
  console.error('Row count verification failed. Destination must have at least source row count for append-only sync:');
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(`Row count verification OK. Tables checked: ${sourceCounts.size}.`);
NODE

  rm -rf "$workdir"
  echo "Append sync and verification completed successfully for $label."
  echo "::endgroup::"
}

ensure_destination_database() {
  local admin_url="$1"
  local database_name="$2"

  echo "Ensuring destination database exists for $database_name..."

  if psql "$admin_url" -v ON_ERROR_STOP=1 -Atc "select datname from pg_database;" | grep -Fxq "$database_name"; then
    return
  fi

  node - "$database_name" <<'NODE' | psql "$admin_url" -v ON_ERROR_STOP=1
const databaseName = process.argv[2];
const identifier = `"${databaseName.replace(/"/g, '""')}"`;
console.log(`create database ${identifier};`);
NODE
}

update_render_services() {
  if [[ -z "${RENDER_API_KEY:-}" && -z "${RENDER_SERVICE_IDS:-}" && -z "${RENDER_ENV_GROUP_ID:-}" ]]; then
    echo "Render env update skipped: RENDER_API_KEY, RENDER_ENV_GROUP_ID, and RENDER_SERVICE_IDS are not configured."
    return
  fi

  if [[ -z "${RENDER_API_KEY:-}" ]]; then
    echo "RENDER_API_KEY is required when Render env updates are configured." >&2
    exit 1
  fi

  if [[ -z "${SOURCE_MASTER_DATABASE_URL:-}" ]]; then
    echo "Render env update requires SOURCE_MASTER_DATABASE_URL to be selected." >&2
    exit 1
  fi

  echo "::group::Promote Render to active database"

  node - "${RENDER_SERVICE_IDS:-}" "${RENDER_ENV_GROUP_ID:-}" "${RENDER_DATABASE_ENV_KEY:-}" "${RENDER_MASTER_DATABASE_ENV_KEY:-MASTER_DATABASE_URL}" "${RENDER_TENANT_TEMPLATE_ENV_KEY:-TENANT_DATABASE_URL_TEMPLATE}" "$SOURCE_MASTER_DATABASE_URL" "${RENDER_DEPLOY_MODE:-deploy_only}" "${RENDER_HEALTH_URLS:-}" "${RENDER_DEPLOY_TIMEOUT_SECONDS:-900}" "${RENDER_HEALTH_TIMEOUT_SECONDS:-180}" "$STATUS_FILE" <<'NODE'
const [
  serviceIdsCsv,
  envGroupId,
  legacyEnvKey,
  masterEnvKey,
  tenantTemplateEnvKey,
  masterDatabaseUrl,
  deployMode,
  healthUrlsCsv,
  deployTimeoutSecondsRaw,
  healthTimeoutSecondsRaw,
  statusFile,
] = process.argv.slice(2);

const apiKey = process.env.RENDER_API_KEY;
const serviceIds = serviceIdsCsv.split(',').map((value) => value.trim()).filter(Boolean);
const healthUrls = healthUrlsCsv.split(',').map((value) => value.trim()).filter(Boolean);
const deployTimeoutMs = Number(deployTimeoutSecondsRaw || 900) * 1000;
const healthTimeoutMs = Number(healthTimeoutSecondsRaw || 180) * 1000;
const pollIntervalMs = 10000;

function encodePath(value) {
  return encodeURIComponent(value);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function renderRequest(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      accept: 'application/json',
      authorization: `Bearer ${apiKey}`,
      'content-type': 'application/json',
      ...(options.headers || {}),
    },
  });

  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}: ${text}`);
  }

  return text ? JSON.parse(text) : null;
}

function tenantTemplateFromMasterUrl(value) {
  return value.replace(/(postgres(?:ql)?:\/\/[^/?#]+)\/[^?#]*/, '$1/{db}');
}

function envVarValue(payload) {
  if (payload?.envVar?.value !== undefined) return payload.envVar.value;
  if (payload?.value !== undefined) return payload.value;
  return '';
}

function deployId(payload) {
  return payload?.deploy?.id || payload?.id;
}

function deployStatus(payload) {
  return payload?.deploy?.status || payload?.status || '';
}

function deployBody() {
  return JSON.stringify({
    clearCache: deployMode === 'build_and_deploy' ? 'clear' : 'do_not_clear',
  });
}

function writeStatus(key, value) {
  const fs = require('fs');
  fs.appendFileSync(statusFile, `${key}=${value ? 1 : 0}\n`);
}

async function getEnvValue(scope, id, key) {
  const prefix = scope === 'group'
    ? `https://api.render.com/v1/env-groups/${encodePath(id)}`
    : `https://api.render.com/v1/services/${encodePath(id)}`;
  const payload = await renderRequest(`${prefix}/env-vars/${encodePath(key)}`, { method: 'GET' });
  return envVarValue(payload);
}

async function putEnvValue(scope, id, key, value) {
  const prefix = scope === 'group'
    ? `https://api.render.com/v1/env-groups/${encodePath(id)}`
    : `https://api.render.com/v1/services/${encodePath(id)}`;
  await renderRequest(`${prefix}/env-vars/${encodePath(key)}`, {
    method: 'PUT',
    body: JSON.stringify({ value }),
  });
}

async function triggerDeploy(serviceId) {
  const payload = await renderRequest(`https://api.render.com/v1/services/${encodePath(serviceId)}/deploys`, {
    method: 'POST',
    body: deployBody(),
  });
  const id = deployId(payload);
  if (!id) throw new Error(`Render did not return a deploy id for ${serviceId}.`);
  console.log(`Render deploy ${id} triggered for ${serviceId}.`);
  return id;
}

async function waitForDeploy(serviceId, id, label) {
  const deadline = Date.now() + deployTimeoutMs;
  const success = new Set(['live', 'succeeded', 'success']);
  const failed = new Set(['build_failed', 'update_failed', 'pre_deploy_failed', 'failed', 'canceled', 'cancelled']);

  while (Date.now() < deadline) {
    const payload = await renderRequest(`https://api.render.com/v1/services/${encodePath(serviceId)}/deploys/${encodePath(id)}`, {
      method: 'GET',
    });
    const status = deployStatus(payload);
    console.log(`${label} deploy ${id} for ${serviceId}: ${status}`);

    if (success.has(status)) return;
    if (failed.has(status)) throw new Error(`${label} deploy ${id} for ${serviceId} ended with ${status}.`);

    await sleep(pollIntervalMs);
  }

  throw new Error(`${label} deploy ${id} for ${serviceId} did not finish within ${deployTimeoutMs / 1000}s.`);
}

async function checkHealth() {
  if (!healthUrls.length) {
    console.log('Health checks skipped: RENDER_HEALTH_URLS is not configured.');
    return;
  }

  const deadline = Date.now() + healthTimeoutMs;
  const pending = new Set(healthUrls);

  while (Date.now() < deadline && pending.size) {
    for (const url of [...pending]) {
      try {
        const response = await fetch(url, { method: 'GET' });
        console.log(`Health ${url}: ${response.status}`);
        if (response.ok) pending.delete(url);
      } catch (error) {
        console.log(`Health ${url}: ${error.message}`);
      }
    }

    if (pending.size) await sleep(10000);
  }

  if (pending.size) {
    throw new Error(`Health checks failed for: ${[...pending].join(', ')}`);
  }
}

async function triggerAndWait(label) {
  if (!serviceIds.length) {
    console.log(`${label} deploy skipped: RENDER_SERVICE_IDS is empty.`);
    return;
  }

  const deploys = [];
  for (const serviceId of serviceIds) {
    deploys.push({ serviceId, id: await triggerDeploy(serviceId) });
  }

  for (const deploy of deploys) {
    await waitForDeploy(deploy.serviceId, deploy.id, label);
  }
}

const updates = [
  { key: masterEnvKey, value: masterDatabaseUrl },
  { key: tenantTemplateEnvKey, value: tenantTemplateFromMasterUrl(masterDatabaseUrl) },
];

if (legacyEnvKey) {
  updates.push({ key: legacyEnvKey, value: masterDatabaseUrl });
}

async function main() {
  const scope = envGroupId ? 'group' : 'service';
  const targetIds = envGroupId ? [envGroupId] : serviceIds;
  if (!targetIds.length) throw new Error('Configure RENDER_ENV_GROUP_ID or RENDER_SERVICE_IDS.');

  const previous = [];
  for (const targetId of targetIds) {
    for (const update of updates) {
      previous.push({
        scope,
        targetId,
        key: update.key,
        value: await getEnvValue(scope, targetId, update.key),
      });
    }
  }

  let promoted = false;
  try {
    console.log('Updating Render environment values to active database.');
    for (const targetId of targetIds) {
      for (const update of updates) {
        await putEnvValue(scope, targetId, update.key, update.value);
        console.log(`Updated ${scope} ${targetId} key ${update.key}.`);
      }
    }

    await triggerAndWait('promotion');
    await checkHealth();
    promoted = true;
    console.log('Render promotion and health checks completed successfully.');
  } catch (error) {
    console.error(`Render promotion failed: ${error.message}`);
    console.error('Restoring previous Render environment values.');
    writeStatus('ROLLBACK_ATTEMPTED', true);

    for (const item of previous) {
      await putEnvValue(item.scope, item.targetId, item.key, item.value);
      console.log(`Restored ${item.scope} ${item.targetId} key ${item.key}.`);
    }

    await triggerAndWait('rollback');
    await checkHealth();
    writeStatus('ROLLBACK_SUCCEEDED', true);
    throw error;
  }

  if (!promoted) throw new Error('Render promotion did not complete.');
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
NODE

  echo "::endgroup::"
}

pair_file="$(mktemp)"
trap 'rm -f "$pair_file" "$STATUS_FILE"' EXIT
configure_alternating_master_urls
build_pair_file "$pair_file"

while IFS=$'\t' read -r label source_url destination_url excluded_tables; do
  [[ -z "${label:-}" ]] && continue
  if [[ -n "${DESTINATION_MASTER_DATABASE_URL:-}" && "$label" != "masterdb" ]]; then
    ensure_destination_database "$DESTINATION_MASTER_DATABASE_URL" "$label"
  fi
  sync_pair "$label" "$source_url" "$destination_url" "${excluded_tables:-}"
done < "$pair_file"

echo "All configured Neon database syncs completed successfully."
update_render_services

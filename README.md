# Neon Fortnightly Append Sync

This setup syncs data between a primary Neon project and a mirror Neon project on a fixed schedule. The active source changes automatically every half month.

Recommended Neon project names:

- `shaj-retail-primary`
- `shaj-retail-fortnightly-mirror`

## GitHub Secrets

For your master database plus tenant database architecture, add these repository secrets:

- `PRIMARY_MASTER_DATABASE_URL`
- `MIRROR_MASTER_DATABASE_URL`

Use raw Neon PostgreSQL URLs for the `masterdb` database. These names stay fixed: primary is always the primary project URL, mirror is always the mirror project URL. The workflow decides which one is source and which one is destination based on the date.

Example:

```text
PRIMARY_MASTER_DATABASE_URL=postgresql://PRIMARY_USER:PRIMARY_PASSWORD@PRIMARY_HOST/masterdb?sslmode=require&channel_binding=require
MIRROR_MASTER_DATABASE_URL=postgresql://MIRROR_USER:MIRROR_PASSWORD@MIRROR_HOST/masterdb?sslmode=require&channel_binding=require
```

## Sync Direction

By default, `SYNC_DIRECTION=auto`:

- IST day 1-15: primary -> mirror
- IST day 16-month end: mirror -> primary

For manual testing, you can add a repository variable named `SYNC_DIRECTION`:

- `auto`
- `primary-to-mirror`
- `mirror-to-primary`

The workflow will automatically sync:

- `masterdb`
- every tenant DB listed by this query:

```sql
select distinct database_name
from public.tenants
where database_name is not null
  and btrim(database_name) <> ''
order by database_name;
```

It also creates missing destination tenant databases before syncing them.

The older master-source/master-destination mode is still supported with these secrets:

- `SOURCE_MASTER_DATABASE_URL`
- `DESTINATION_MASTER_DATABASE_URL`

Manual pair configuration is still supported with this repository secret:

- `NEON_DATABASE_PAIRS_JSON`

Example manual value:

```json
[
  {
    "label": "masterdb",
    "source": "postgresql://SOURCE_MASTER_USER:SOURCE_MASTER_PASSWORD@SOURCE_MASTER_HOST/masterdb?sslmode=require&channel_binding=require",
    "destination": "postgresql://DEST_MASTER_USER:DEST_MASTER_PASSWORD@DEST_MASTER_HOST/masterdb?sslmode=require&channel_binding=require"
  },
  {
    "label": "tenant_acme",
    "source": "postgresql://SOURCE_TENANT_USER:SOURCE_TENANT_PASSWORD@SOURCE_TENANT_HOST/tenant_acme?sslmode=require&channel_binding=require",
    "destination": "postgresql://DEST_TENANT_USER:DEST_TENANT_PASSWORD@DEST_TENANT_HOST/tenant_acme?sslmode=require&channel_binding=require"
  }
]
```

Each source tenant database needs its own matching destination tenant database.

The older single-database mode is also still supported with these secrets:

- `NEON_SOURCE_DATABASE_URL`: connection string for `shaj-retail-primary`
- `NEON_DESTINATION_DATABASE_URL`: connection string for `shaj-retail-fortnightly-mirror`

Do not commit database URLs or passwords into the repository.

## Optional GitHub Variables

Add this repository variable only if you want to skip table data:

- `NEON_SYNC_EXCLUDED_TABLES`: comma-separated table names, for example `public.audit_logs,public.sessions`
- `TENANT_DATABASE_QUERY`: custom SQL query for discovering tenant database names, if `public.tenants.database_name` changes later.
- `SYNC_DIRECTION`: use `auto`, `primary-to-mirror`, or `mirror-to-primary`.

## Optional Render Update

The workflow can update Render after a successful sync so your app points to the active database for the current half month.

Add this repository secret:

- `RENDER_API_KEY`

Add these repository variables:

- `RENDER_SERVICE_IDS`: comma-separated Render service IDs, for example `srv-abc123,srv-def456`
- `RENDER_DATABASE_ENV_KEY`: optional, defaults to `DATABASE_URL`
- `RENDER_DEPLOY_MODE`: optional, defaults to `build_and_deploy`; use `deploy_only` if your app only needs a runtime redeploy

After verification passes, the workflow updates the configured Render env var to the active `masterdb` URL and triggers a Render deploy for each service.

## Schedule

The workflow runs at 02:00 IST on the 1st and 16th of every month. GitHub Actions cron cannot express an exact rolling "every 15 days forever" schedule cleanly, so this is the most predictable fortnightly calendar schedule.

You can also run it manually from GitHub:

`Actions -> Neon fortnightly append sync -> Run workflow`

## Behavior

- Chooses sync direction automatically from the IST date.
- Runs each configured database pair separately.
- In master-based mode, discovers tenant database names from `masterdb`.
- Creates missing destination tenant databases.
- Creates any missing schema objects from the source schema where possible.
- Adds missing destination columns before importing data.
- Appends source rows into the destination.
- Uses `ON CONFLICT DO NOTHING`, so rows that already exist by primary key or unique constraint are skipped.
- Does not delete destination data.
- Verifies after each database sync that destination has every source table, every source column with the same type, and at least the source row count for each non-excluded table.
- Optionally updates Render service env vars and triggers deploys after verification.

If a table has no primary key or unique constraint, repeated runs can duplicate its rows. Add a unique key to those tables if they must remain deduplicated.

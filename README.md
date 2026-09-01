# Neon Fortnightly Append Sync

This setup copies data from the primary Neon database into a mirror Neon database on a fixed schedule.

Recommended Neon project names:

- `shaj-retail-primary`
- `shaj-retail-fortnightly-mirror`

## GitHub Secrets

For a master database plus tenant databases, add this repository secret:

- `NEON_DATABASE_PAIRS_JSON`

Example value:

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

The older single-database mode is still supported with these secrets:

- `NEON_SOURCE_DATABASE_URL`: connection string for `shaj-retail-primary`
- `NEON_DESTINATION_DATABASE_URL`: connection string for `shaj-retail-fortnightly-mirror`

Do not commit database URLs or passwords into the repository.

## Optional GitHub Variable

Add this repository variable only if you want to skip table data:

- `NEON_SYNC_EXCLUDED_TABLES`: comma-separated table names, for example `public.audit_logs,public.sessions`

## Schedule

The workflow runs at 02:00 IST on the 1st and 16th of every month. GitHub Actions cron cannot express an exact rolling "every 15 days forever" schedule cleanly, so this is the most predictable fortnightly calendar schedule.

You can also run it manually from GitHub:

`Actions -> Neon fortnightly append sync -> Run workflow`

## Behavior

- Runs each configured database pair separately.
- Creates any missing schema objects from the source schema where possible.
- Adds missing destination columns before importing data.
- Appends source rows into the destination.
- Uses `ON CONFLICT DO NOTHING`, so rows that already exist by primary key or unique constraint are skipped.
- Does not delete destination data.

If a table has no primary key or unique constraint, repeated runs can duplicate its rows. Add a unique key to those tables if they must remain deduplicated.

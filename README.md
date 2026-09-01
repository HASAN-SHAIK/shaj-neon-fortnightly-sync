# Neon Fortnightly Append Sync

This setup copies data from the primary Neon database into a mirror Neon database on a fixed schedule.

Recommended Neon project names:

- `shaj-retail-primary`
- `shaj-retail-fortnightly-mirror`

## GitHub Secrets

Add these repository secrets in GitHub:

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

- Creates any missing schema objects from the source schema where possible.
- Adds missing destination columns before importing data.
- Appends source rows into the destination.
- Uses `ON CONFLICT DO NOTHING`, so rows that already exist by primary key or unique constraint are skipped.
- Does not delete destination data.

If a table has no primary key or unique constraint, repeated runs can duplicate its rows. Add a unique key to those tables if they must remain deduplicated.

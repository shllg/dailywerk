# Backup And Restore

The deployment RFC expects compressed and encrypted backups, even though backup automation itself is not implemented in this repo yet.

Minimum backup scope:

- PostgreSQL dumps for `dailywerk_production` and `dailywerk_staging`
- `/srv/dailywerk/data/`
- `/srv/dailywerk/config/`
- `/srv/dailywerk/runtime/`
- observability volumes if dashboards and Loki history matter

Recommended commands:

```bash
pg_dump -Fc "$DATABASE_URL" > /srv/dailywerk/backups/dailywerk-production.dump
restic backup --compression max /srv/dailywerk/data /srv/dailywerk/config /srv/dailywerk/runtime
```

Restore drill checklist:

1. Read the restic password from `op://DailyWerk Production/backup/restic-password`.
2. Restore into a temporary directory.
3. Restore a PostgreSQL dump into a temporary database.
4. Verify at least one workspace file and one DB table.

Do not treat backups as valid until a restore drill has succeeded.

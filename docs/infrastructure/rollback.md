# Rollback

Rollback is a slot switch, not a rebuild.

Immediate rollback steps:

1. Check the current markers in `/srv/dailywerk/runtime/`.
2. Identify the previous slot for the affected environment.
3. Run [switch-slot.sh](/home/sascha/src/dailywerk/dailywerk/deploy/scripts/switch-slot.sh) with the previous slot.
4. If that slot was already stopped, restart it with [app-slot.yml](/home/sascha/src/dailywerk/dailywerk/deploy/compose/app-slot.yml).

Example:

```bash
/srv/dailywerk/deploy/scripts/switch-slot.sh production blue

APP_ENVIRONMENT=production \
APP_ENV_FILE=/srv/dailywerk/config/env/prod-blue.env \
API_IMAGE=ghcr.io/<owner>/dailywerk-api@sha256:<digest> \
FRONTEND_IMAGE=ghcr.io/<owner>/dailywerk-frontend@sha256:<digest> \
WORKSPACE_ROOT=/srv/dailywerk/data/prod \
docker compose -p dailywerk-prod-blue -f /srv/dailywerk/deploy/compose/app-slot.yml up -d
```

If the bad deploy included a non-backward-compatible migration, stop and use the migration-specific rollback plan before switching traffic.

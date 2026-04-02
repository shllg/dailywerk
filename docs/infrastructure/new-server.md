# New Server

This repo assumes a server root of `/srv/dailywerk`.

Bootstrap order:

1. Provision the Debian host and harden SSH, firewall, and packages.
2. Install Docker Engine, Compose, Tailscale, and the 1Password CLI.
3. Create `/srv/dailywerk/{deploy,config,data,backups,runtime}`.
4. Copy this repo's `deploy/` directory to `/srv/dailywerk/deploy/`.
5. Place `OP_SERVICE_ACCOUNT_TOKEN` in `/srv/dailywerk/config/env/op-token.env`.
6. Start infra, observability, and edge compose projects.
7. Confirm Grafana, Nginx, PostgreSQL, and Valkey are healthy.
8. Trigger the first staging deploy, then production.

First-start commands:

```bash
docker compose -f /srv/dailywerk/deploy/compose/infra.yml up -d
docker compose -f /srv/dailywerk/deploy/compose/observability.yml up -d
docker compose -f /srv/dailywerk/deploy/compose/edge.yml up -d
```

Do not build application images on the server. The host should only pull signed GHCR images and run the checked-in deploy scripts.

# Incident Response

Start with the narrowest failing layer.

Traffic or readiness issues:

1. `curl -fsS https://app.dailywerk.com/ready`
2. `docker compose -f /srv/dailywerk/deploy/compose/edge.yml logs --tail=200`
3. Check `/srv/dailywerk/runtime/prod-active-slot`
4. If the new slot is bad, switch back immediately with [switch-slot.sh](/home/sascha/src/dailywerk/dailywerk/deploy/scripts/switch-slot.sh)

Queue or job issues:

1. Open Grafana and inspect `dailywerk_good_job_queue_depth`
2. Check the worker container logs
3. Confirm `GOOD_JOB_ENABLE_CRON` is correct for the environment

Database or Valkey issues:

1. Inspect the `dailywerk-infra` compose project
2. Confirm PostgreSQL and Valkey healthchecks are green
3. Verify the `DATABASE_URL` and `VALKEY_URL` currently rendered for the active slot

Log and metrics entry points:

- Grafana: `http://dailywerk-ops:3000`
- Loki via Grafana Explore
- Prometheus scrape status via the Grafana datasource

# Deploy

The production and staging deploy path is image-driven:

1. `master` publishes production images and `dev` publishes staging images for `dailywerk-api`, `dailywerk-frontend`, and `dailywerk-deploy-listener` to GHCR.
2. [publish-images.yml](/home/sascha/src/dailywerk/dailywerk/.github/workflows/publish-images.yml) calls [deploy-notify.yml](/home/sascha/src/dailywerk/dailywerk/.github/workflows/deploy-notify.yml).
3. The deploy listener receives the signed webhook on `POST /deploy`.
4. [perform-deploy.sh](/home/sascha/src/dailywerk/dailywerk/deploy/scripts/perform-deploy.sh) renders the inactive slot env, runs migrations, starts the slot, waits for `/ready`, switches Nginx, annotates Grafana, then stops the old slot.

Host prerequisites:

- `/srv/dailywerk/deploy/` contains the checked-in `deploy/` tree from this repo.
- `/srv/dailywerk/config/env/op-token.env` exports `OP_SERVICE_ACCOUNT_TOKEN`.
- GHCR images are pullable by the host.
- `/srv/dailywerk/runtime/prod-active-slot` and `/srv/dailywerk/runtime/staging-active-slot` exist or default to `blue`.

Useful commands:

```bash
docker compose -f /srv/dailywerk/deploy/compose/infra.yml up -d
docker compose -f /srv/dailywerk/deploy/compose/observability.yml up -d
docker compose -f /srv/dailywerk/deploy/compose/edge.yml up -d
curl -fsS https://app.dailywerk.com/ready
curl -fsS https://staging.dailywerk.com/ready
```

Manual deploy trigger:

```bash
payload='{"environment":"production","api_image":"ghcr.io/<owner>/dailywerk-api@sha256:<digest>","frontend_image":"ghcr.io/<owner>/dailywerk-frontend@sha256:<digest>","build_sha":"<sha>","build_ref":"master"}'
signature="sha256=$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$DEPLOY_WEBHOOK_SECRET" -binary | xxd -p -c 256)"
curl -fsS -X POST http://127.0.0.1:8081/deploy \
  -H "Content-Type: application/json" \
  -H "X-DailyWerk-Signature: $signature" \
  -d "$payload"
```

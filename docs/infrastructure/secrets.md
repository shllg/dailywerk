# Secrets

Secrets are stored in 1Password and resolved at deploy time.

Required vaults:

- `DailyWerk Production`
- `DailyWerk Staging`
- `DailyWerk Shared`

The deploy scripts read these paths directly:

- `op://DailyWerk Production/rails/master-key`
- `op://DailyWerk Production/rails/secret-key-base`
- `op://DailyWerk Production/database/url`
- `op://DailyWerk Production/valkey/url`
- `op://DailyWerk Production/workos/api-key`
- `op://DailyWerk Production/workos/client-id`
- `op://DailyWerk Production/stripe/secret-key`
- `op://DailyWerk Production/stripe/webhook-secret`
- `op://DailyWerk Production/stripe/publishable-key`
- `op://DailyWerk Production/storage/access-key-id`
- `op://DailyWerk Production/storage/secret-access-key`
- `op://DailyWerk Production/storage/endpoint`
- `op://DailyWerk Production/storage/region`
- `op://DailyWerk Production/storage/bucket`
- `op://DailyWerk Production/metrics/basic-auth-username`
- `op://DailyWerk Production/metrics/basic-auth-password`
- `op://DailyWerk Shared/deploy/webhook-secret`

Server-side minimum:

- `/srv/dailywerk/config/env/op-token.env` must export `OP_SERVICE_ACCOUNT_TOKEN`.
- The deploy listener may also use `GRAFANA_API_KEY_OP_PATH` if Grafana annotations are enabled.

The runtime env files under `/srv/dailywerk/config/env/` are generated artifacts, not source-of-truth secrets.

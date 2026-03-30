# Dailywerk

Rails 8.1 API + React 19 SPA for daily work management.

## Stack

- **Backend**: Ruby 4.0, Rails 8.1 (API-only), PostgreSQL 17, Valkey 8, GoodJob
- **Frontend**: React 19, TypeScript, Vite 8
- **Storage**: RustFS (S3-compatible)

## Setup

```bash
cp .env.development.example .env.development
docker compose up -d
bin/rails db:setup
cd frontend && pnpm install
```

## Development

```bash
bin/rails server            # API on :3000
cd frontend && pnpm dev     # SPA on :5173
bin/rails test              # backend tests
cd frontend && pnpm test    # frontend tests
```

## Commit Messages

Format: `[CATEGORY] Short imperative summary` (50 chars max, no trailing punctuation)

| Category     | Use for                                  |
|--------------|------------------------------------------|
| `[FIX]`      | Bug fixes                                |
| `[FEATURE]`  | New functionality                        |
| `[REFACTOR]` | Code restructuring without behavior change |
| `[CHORE]`    | Tooling, config, dev-only changes        |
| `[TEST]`     | Test-only changes                        |
| `[DOCS]`     | Documentation                            |

Body (optional): bullet points, imperative mood.

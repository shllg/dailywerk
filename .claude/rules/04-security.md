# Security

> **Purpose:** OWASP, auth, encryption, injection prevention.

## Strong Parameters

- Explicit `permit` allowlists on every controller action
- Never `permit!` — always name individual attributes
- Use `attr_readonly` for fields that should never change after creation

## SQL Injection Prevention

- Parameterized queries only (ActiveRecord handles this)
- Never interpolate user input into SQL strings
- Never use raw `constantize` on user input — maintain allowlists

## Encryption

- API keys and credentials: `ActiveRecord::Encryption` (non-deterministic mode)
- Never store secrets in code — use Rails credentials or environment variables

## Authentication (WorkOS)

- SSO, social login, magic links via WorkOS
- Session management via WorkOS-issued tokens
- API-mode Rails: token-based auth (no cookies = no CSRF for API)
- If cookies added later: enable CSRF protection

## Mass Assignment

- Strong parameters on all controllers (see above)
- `attr_readonly` for immutable fields (e.g., `user_id` after creation)

## Dependencies

- `bundler-audit` for Ruby dependency CVEs
- `brakeman` for static security analysis
- Run both in CI and before releases

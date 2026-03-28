---
paths:
  - "app/models/**"
  - "db/migrate/**"
---

# Data Conventions

> **Purpose:** PostgreSQL, UUIDv7, indexing, and migration safety.

## UUIDv7 Primary Keys

All tables use UUIDv7: `id :uuid, default: -> { "gen_random_uuid_v7()" }`.
Time-ordered, 128-bit, RFC 9562. No integer IDs.

Foreign keys are also `uuid` type:
```ruby
t.references :user, type: :uuid, null: false, foreign_key: true
```

## Migration Safety

- Use `strong_migrations` gem — prevents unsafe DDL (locking ALTER TABLE, etc.)
- All migrations must be reversible
- Index every foreign key and every column used in WHERE clauses
- Add indexes concurrently for existing tables: `add_index :table, :col, algorithm: :concurrently`

## N+1 Prevention

- Use `strict_loading` on associations where appropriate
- Use `includes` / `preload` for known association access patterns
- Consider Bullet gem in development for detection

## pgvector (When Added)

- Extension: `vector` (via `neighbor` gem)
- Embedding columns always scoped by `user_id`
- Index type: HNSW for approximate nearest neighbor
- Hybrid search: semantic (cosine) + fulltext (ts_rank) via Reciprocal Rank Fusion

## Query Scopes

- Prefer named scopes over raw `where` chains in controllers
- Keep scopes simple — complex queries belong in service objects

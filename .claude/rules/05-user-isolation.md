---
paths:
  - "app/models/**"
  - "app/services/**"
  - "app/jobs/**"
  - "app/controllers/**"
  - "db/migrate/**"
  - "lib/**"
---

# User Isolation — Workspace RLS

> **Purpose:** Row-level security patterns so every query is automatically scoped to the current workspace.

## Two-Layer Defence

| Layer | Mechanism | Enforces |
|-------|-----------|----------|
| Application | `WorkspaceScoped` default_scope | Filters every ActiveRecord query |
| Database | PostgreSQL RLS policy `workspace_isolation` | Blocks any row not matching `app.current_workspace_id` session var |

The DB-level RLS only fires for the `app_user` non-superuser role. Superuser connections (migrations, `rails console` as a superuser) bypass RLS by design.

## WorkspaceScoped Concern

Include in any model that lives inside a workspace.

```ruby
class Agent < ApplicationRecord
  include WorkspaceScoped
  # ...
end
```

**What it does automatically:**
- `default_scope` filters by `Current.workspace` when set, returns `none` when `Current.workspace` is nil (and scoping is active), returns `all` when `Current.skip_workspace_scoping?` is true
- `belongs_to :workspace` + presence validation
- `before_validation :set_workspace_from_context` on create — sets `workspace` from `Current.workspace`
- Validates `workspace` matches `Current.workspace` on create
- Validates `workspace_id` is immutable on update

## WorkspaceScopedJob Concern

Include in any job that operates on workspace-owned records.

```ruby
class SomeJob < ApplicationJob
  include WorkspaceScopedJob

  def perform(record_id, workspace_id:, user_id: nil)
    # Current.workspace and Current.user are set, PG session var is live
  end
end
```

**What it does:**
- Wraps `around_perform` with `set_workspace_context`
- Extracts `workspace_id:` (and optionally `user_id:`) from the last keyword argument in `arguments`
- Sets `Current.workspace` + `Current.user`
- Executes `SET app.current_workspace_id = '...'` on the DB connection
- Resets both on exit (even on exception)
- Raises `ArgumentError` if `workspace_id:` is missing

## RlsMigrationHelpers

`require_relative "../../lib/rls_migration_helpers"` at the top of the migration.

| Method | Use when |
|--------|----------|
| `enable_workspace_rls!(table)` | Table has a direct `workspace_id` column |
| `enable_parent_rls!(table, parent_table:, parent_fk:)` | Table inherits workspace through a parent FK (no `workspace_id` on child) |
| `disable_workspace_rls!(table)` | Reverse of `enable_workspace_rls!` |
| `disable_parent_rls!(table)` | Reverse of `enable_parent_rls!` |

`APP_ROLE = "app_user"` — the non-superuser PostgreSQL role targeted by all RLS policies.

## Migration Template

```ruby
require_relative "../../lib/rls_migration_helpers"

class CreateThings < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :things, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      # ... columns ...
      t.timestamps
      t.index %i[workspace_id some_column]
    end

    safety_assured { enable_workspace_rls!(:things) }
  end

  def down
    safety_assured { disable_workspace_rls!(:things) }
    drop_table :things
  end
end
```

For child tables (e.g. `tool_calls` that belong to `messages`):

```ruby
safety_assured do
  enable_parent_rls!(:tool_calls, parent_table: :messages, parent_fk: :message_id)
end
```

## Cross-Workspace Jobs

Jobs that operate across workspaces (e.g. archiving stale sessions for all users) must bypass the default_scope using `Current.without_workspace_scoping`:

```ruby
Current.without_workspace_scoping do
  Session.active.stale(threshold).find_each do |session|
    session.archive!
  end
end
```

**NEVER use `unscoped`** — it strips all default scopes including any added later. `Current.without_workspace_scoping` is reversible and scope-aware.

## Test Isolation

All tests that touch workspace-scoped models must use these two helpers from `test/test_helper.rb`:

```ruby
# Create a user + workspace pair
user, workspace = create_user_with_workspace

# Set Current.user + Current.workspace for the block
with_current_workspace(workspace, user:) do
  agent = Agent.create!(name: "My Agent", ...)
  assert_equal 1, Agent.count
end
```

`create_user_with_workspace` creates a `User`, `Workspace`, and `WorkspaceMembership` (role: "owner"). It accepts keyword overrides for `email:`, `name:`, and `workspace_name:`.

`with_current_workspace` saves and restores `Current.user` / `Current.workspace` around the block.

## MUST Rules

- **MUST** include `WorkspaceScoped` on every model with a `workspace_id` column
- **MUST** include `WorkspaceScopedJob` on every job that reads or writes workspace-owned records
- **MUST** call `enable_workspace_rls!` or `enable_parent_rls!` in the `up` migration for every workspace-owned table
- **MUST** wrap RLS DDL in `safety_assured { ... }` (strong_migrations cannot auto-analyse DDL)
- **MUST** use `Current.without_workspace_scoping` for cross-workspace queries in jobs
- **MUST** use `create_user_with_workspace` + `with_current_workspace` in tests — never set `Current.*` directly in test setup without restoring

## NEVER Rules

- **NEVER** call `unscoped` to bypass workspace filtering — use `Current.without_workspace_scoping`
- **NEVER** omit `workspace_id:` from a `WorkspaceScopedJob` perform call — the concern raises `ArgumentError`
- **NEVER** set `workspace_id` in a controller — always let `WorkspaceScoped#set_workspace_from_context` derive it from `Current.workspace`
- **NEVER** create a workspace-owned table without a corresponding RLS policy

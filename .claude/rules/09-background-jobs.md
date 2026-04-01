---
paths:
  - "app/jobs/**"
  - "config/initializers/good_job.rb"
---

# Background Jobs

> **Purpose:** GoodJob patterns, job types, concurrency controls, and queue conventions.

## Execution Mode

GoodJob runs in **external mode only** — a separate worker process started by `bin/dev`. Never configure inline or async mode. This is non-negotiable because Falcon uses fibers and inline job execution would block the reactor.

## Two Job Types

| Type | Concern | Arguments | Use when |
|------|---------|-----------|----------|
| Workspace-scoped | `WorkspaceScopedJob` | positional args + `workspace_id:` keyword | Job reads/writes workspace-owned records |
| Cross-workspace | none | no workspace context | Job operates across all workspaces (cron maintenance) |

## Workspace-Scoped Job Pattern

Include `WorkspaceScopedJob`. Always accept `workspace_id:` as a keyword argument. The concern wraps `around_perform` to set `Current.workspace`, `Current.user`, and the PostgreSQL `app.current_workspace_id` session variable before `perform` runs, then resets them on exit.

```ruby
class SomeJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param record_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(record_id, workspace_id:)
    record = SomeModel.find(record_id)
    # Current.workspace is already set — workspace-scoped queries work normally
    DoSomethingService.new(record).call
  end
end
```

Enqueue with the keyword argument:

```ruby
SomeJob.perform_later(record.id, workspace_id: record.workspace_id)
```

## Cross-Workspace Job Pattern

Do not include `WorkspaceScopedJob`. Use `Current.without_workspace_scoping` to bypass the default scope for queries that span all workspaces. Use `find_each` for batch processing to avoid loading all records into memory.

```ruby
class ArchiveStaleSessionsJob < ApplicationJob
  STALE_THRESHOLD = 7.days

  queue_as :default

  # @return [void]
  def perform
    Current.without_workspace_scoping do
      Session.stale(STALE_THRESHOLD.ago).find_each do |session|
        session.archive!
      end
    end
  end
end
```

**NEVER use `unscoped`** — use `Current.without_workspace_scoping` instead. `unscoped` strips all default scopes including any added later and is not reversible.

## GoodJob Concurrency Controls

Include `GoodJob::ActiveJobExtensions::Concurrency` to limit concurrent executions of a job. Use a dynamic key to scope the limit per record:

```ruby
class CompactionJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    perform_limit: 1,    # max concurrent performs
    total_limit: 2,      # max queued + performing combined
    key: -> { "compaction_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  def perform(session_id, workspace_id:)
    # ...
  end
end
```

Do not use PostgreSQL advisory locks — use GoodJob's built-in concurrency extension instead.

## Cron Registration

Register cron jobs in `config/initializers/good_job.rb`:

```ruby
Rails.application.configure do
  config.good_job.preserve_job_records = true
  config.good_job.retry_on_unhandled_error = false
  config.good_job.on_thread_error = ->(exception) { Rails.logger.error(exception) }
  config.good_job.cron = {
    archive_stale_sessions: {
      cron: "0 3 * * *",
      class: "ArchiveStaleSessionsJob",
      description: "Archive sessions inactive for more than 7 days"
    }
  }
end
```

## Queue Names

| Queue | Used for |
|-------|----------|
| `:default` | General background work (compaction, archiving, etc.) |
| `:llm` | Streaming LLM turns (`ChatStreamJob`) |

## Idempotency

All jobs must be safe to run more than once for the same input. `discard_on ActiveRecord::RecordNotFound` prevents repeated failures when the target record was deleted between enqueue and execution.

## MUST Rules

- **MUST** use `WorkspaceScopedJob` on every job that reads or writes workspace-owned records
- **MUST** pass `workspace_id:` as a keyword argument when enqueuing workspace-scoped jobs
- **MUST** use `Current.without_workspace_scoping` for cross-workspace queries — never `unscoped`
- **MUST** use `find_each` for batch processing — never load an unbounded collection into memory
- **MUST** add `discard_on ActiveRecord::RecordNotFound` to jobs that look up a record by ID
- **MUST** use GoodJob concurrency extension instead of advisory locks when limiting parallel executions
- **MUST** register cron jobs in `config/initializers/good_job.rb`

## NEVER Rules

- **NEVER** configure GoodJob in inline or async mode — external worker process only
- **NEVER** make LLM HTTP calls in the Falcon request cycle — always enqueue a job
- **NEVER** use PostgreSQL advisory locks — use `GoodJob::ActiveJobExtensions::Concurrency`
- **NEVER** call `unscoped` to bypass workspace filtering — use `Current.without_workspace_scoping`
- **NEVER** omit `workspace_id:` from a `WorkspaceScopedJob` enqueue call — the concern raises `ArgumentError` at runtime

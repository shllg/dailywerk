# Rails Job Skill

Copy-paste templates for background jobs. Jobs live in `app/jobs/`.

GoodJob runs in **external mode only**. Never configure inline or async mode.

## Workspace-Scoped Job

For jobs that read or write workspace-owned records.

```ruby
# frozen_string_literal: true

# One-line doc: what this job does.
class DoSomethingJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param record_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(record_id, workspace_id:)
    # Current.workspace is already set by WorkspaceScopedJob#around_perform
    record = SomeModel.find(record_id)
    DoSomethingService.new(record).call
  end
end
```

Enqueue with the keyword argument:

```ruby
DoSomethingJob.perform_later(record.id, workspace_id: record.workspace_id)
```

Key points:
- `include WorkspaceScopedJob` — sets `Current.workspace`, `Current.user`, and `app.current_workspace_id` PG session var before `perform`, resets on exit
- `workspace_id:` keyword is required — the concern raises `ArgumentError` if missing
- `discard_on ActiveRecord::RecordNotFound` — prevents repeated failures when the record was deleted
- LLM jobs use `queue_as :llm`; everything else uses `:default`

## With Concurrency Controls

For jobs where duplicate concurrent executions would cause data corruption (e.g. compaction).

```ruby
class CompactThingJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    perform_limit: 1,
    total_limit: 2,
    key: -> { "compact_thing_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param thing_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(thing_id, workspace_id:)
    thing = Thing.find(thing_id)
    CompactThingService.new(thing).compact!
  end
end
```

Do not use PostgreSQL advisory locks — use `GoodJob::ActiveJobExtensions::Concurrency` instead.

## Cross-Workspace Cron Job

For maintenance jobs that operate across all workspaces (no `WorkspaceScopedJob`).

```ruby
# frozen_string_literal: true

# One-line doc: what this job does across all workspaces.
class CleanupStaleThingsJob < ApplicationJob
  STALE_THRESHOLD = 30.days

  queue_as :default

  # @return [void]
  def perform
    count = 0

    Current.without_workspace_scoping do
      Thing.where("updated_at < ?", STALE_THRESHOLD.ago).find_each do |thing|
        thing.destroy!
        count += 1
      end
    end

    Rails.logger.info("[CleanupStaleThings] Removed #{count} things")
  end
end
```

Register in `config/initializers/good_job.rb`:

```ruby
config.good_job.cron = {
  cleanup_stale_things: {
    cron: "0 4 * * *",
    class: "CleanupStaleThingsJob",
    description: "Remove things inactive for more than 30 days"
  }
}
```

Key points:
- `Current.without_workspace_scoping` — bypasses default_scope cleanly; never use `unscoped`
- `find_each` — batch processing, never load unbounded collections into memory
- All jobs must be idempotent — safe to run more than once for the same input

## Test Template

```ruby
# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class DoSomethingJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "processes the record and updates its status" do
    user, workspace = create_user_with_workspace

    record = with_current_workspace(workspace, user:) do
      Thing.create!(name: "Widget-#{SecureRandom.hex(4)}")
    end

    with_current_workspace(workspace, user:) do
      DoSomethingJob.perform_now(record.id, workspace_id: workspace.id)
      assert_equal "done", record.reload.status
    end
  end
end
```

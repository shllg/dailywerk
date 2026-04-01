# Rails Testing Skill

Quick reference for writing tests in this codebase.

## Test Types

| What | Base class | Location |
|------|-----------|----------|
| Model / service / concern | `ActiveSupport::TestCase` | `test/models/`, `test/services/` |
| Controller (API) | `ActionDispatch::IntegrationTest` | `test/controllers/api/v1/` |
| Job | `ActiveSupport::TestCase` | `test/jobs/` |

No RSpec. No FactoryBot. No mocking gems. Minitest only.

Tests run in parallel (`parallelize(workers: :number_of_processors)`) — all setup must be parallel-safe.

## Essential Setup

```ruby
# Create a user + workspace pair
user, workspace = create_user_with_workspace

# With unique emails/workspace names (required when multiple in one test)
user_two, workspace_two = create_user_with_workspace(
  email: "other-#{SecureRandom.hex(4)}@dailywerk.com",
  workspace_name: "Other"
)

# Set Current context for workspace-scoped queries
with_current_workspace(workspace, user:) do
  Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "Test", model_id: "gpt-5.4")
  assert_equal 1, Agent.count
end
```

Always use `SecureRandom.hex(4)` in slugs and emails — tests run in parallel.

## Shared Helpers (test/test_helper.rb)

| Helper | Signature | Purpose |
|--------|-----------|---------|
| `create_user_with_workspace` | `(email:, name:, workspace_name:)` | Creates User + Workspace + WorkspaceMembership |
| `with_current_workspace` | `(workspace, user: workspace.owner, &block)` | Sets Current context for the block |
| `api_auth_headers` | `(user:, workspace:)` | Returns `Authorization: Bearer ...` header hash |

## Stubbing

```ruby
original = SomeClass.method(:some_method)
SomeClass.define_singleton_method(:some_method) do |*args|
  # stub body — no mocking gems
end

# ... test code ...
ensure
  SomeClass.define_singleton_method(:some_method, original)
```

Always capture the original and restore in `ensure`.

## Struct-Based Fakes (for service tests)

```ruby
FakeSession = Struct.new(:agent, :calls, :context_window_usage, keyword_init: true) do
  def ask(message)
    calls << [:ask, message]
    :response
  end

  def with_model(model_id, provider:)
    calls << [:with_model, model_id, provider]
    self
  end
end

session = FakeSession.new(agent:, calls: [], context_window_usage: 0.2)
```

See `test/services/agent_runtime_test.rb` for a full example.

## Job Tests

```ruby
require "test_helper"
require "active_job/test_helper"

class SomeJobTest < ActiveSupport::TestCase
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

  test "performs the job" do
    user, workspace = create_user_with_workspace

    record = with_current_workspace(workspace, user:) do
      SomeModel.create!(name: "Test")
    end

    with_current_workspace(workspace, user:) do
      SomeJob.perform_now(record.id, workspace_id: workspace.id)
      record.reload
      assert_equal "done", record.status
    end
  end

  test "enqueues a follow-up job" do
    user, workspace = create_user_with_workspace
    record = with_current_workspace(workspace, user:) { SomeModel.create!(name: "X") }

    assert_enqueued_with(job: FollowUpJob) do
      SomeJob.perform_now(record.id, workspace_id: workspace.id)
    end
  end
end
```

## Controller Tests

```ruby
require "test_helper"
require "active_job/test_helper"

class Api::V1::ThingsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user, @workspace = create_user_with_workspace
    @thing = with_current_workspace(@workspace, user: @user) do
      Thing.create!(name: "Widget")
    end
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "returns the thing" do
    get "/api/v1/things/#{@thing.id}",
        headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @thing.id, body["id"]
  end

  test "returns 422 for invalid input" do
    post "/api/v1/things",
         params: { thing: { name: "" } },
         as: :json,
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :unprocessable_entity
  end
end
```

## Multiple Assertions Pragma

When a test legitimately needs multiple assertions on a complex response shape:

```ruby
# rubocop:disable Minitest/MultipleAssertions
class SomeTest < ActiveSupport::TestCase
  # ...
end
# rubocop:enable Minitest/MultipleAssertions
```

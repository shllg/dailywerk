---
paths:
  - "test/**"
---

# Testing

> **Purpose:** Conventions for writing correct, parallel-safe Minitest tests in this codebase.

## Framework

Minitest only. No RSpec. No FactoryBot. No fixture YAML files.

Parallel execution is enabled globally in `test/test_helper.rb`:

```ruby
parallelize(workers: :number_of_processors, threshold: 50)
```

All test setup must be safe to run across multiple parallel workers.

## Default vs Live LLM Suites

The default Ruby suite is `bin/test`. It is the hermetic suite that CI runs by default and it must not depend on live provider credentials or network calls.

Live provider coverage belongs in `test/llm_integration/` and runs through `bin/test-llm`. That suite is opt-in and gated by `RUN_LIVE_LLM_TESTS=1` plus the relevant provider key such as `OPENAI_API_KEY`.

Treat live LLM tests as scarce smoke tests, not normal coverage:

- Prefer ordinary model/service/job tests for local logic.
- Add a live LLM test only when you need to verify provider wiring, SDK compatibility, or a critical request/response path end-to-end.
- Keep requests tiny and assertions structural.
- Do not add live LLM tests inflationarily.

## Record Creation

Create records inline — no factories, no fixtures. Use `create_user_with_workspace` for workspace-owned records:

```ruby
user, workspace = create_user_with_workspace
# Optional overrides:
user, workspace = create_user_with_workspace(
  email: "other-#{SecureRandom.hex(4)}@dailywerk.com",
  workspace_name: "Other"
)
```

This creates a `User`, `Workspace`, and `WorkspaceMembership` (role: "owner") in one call.

**Always use `SecureRandom.hex(4)` in slugs and emails** to avoid uniqueness collisions between parallel workers.

## Workspace Scoping in Tests

Every test that touches workspace-scoped models MUST wrap record creation and queries in `with_current_workspace`:

```ruby
with_current_workspace(workspace, user:) do
  agent = Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "Test", model_id: "gpt-5.4")
  assert_equal 1, Agent.count
end
```

`with_current_workspace` sets `Current.user` and `Current.workspace` for the block and restores both on exit (even on exception). Never set `Current.*` directly without restoring.

## Shared Helpers (test/test_helper.rb)

| Helper | Signature | Purpose |
|--------|-----------|---------|
| `create_user_with_workspace` | `(email:, name:, workspace_name:)` | Creates User + Workspace + WorkspaceMembership |
| `with_current_workspace` | `(workspace, user: workspace.owner, &block)` | Sets Current context for the block |
| `api_auth_headers` | `(user:, workspace:)` | Returns `Authorization: Bearer ...` header hash |

## Stubbing

Use `define_singleton_method` — no mocking gems. Always capture the original method and restore it in an `ensure` block:

```ruby
original = SomeClass.method(:some_method)
SomeClass.define_singleton_method(:some_method) do |*args|
  # stub body
end

# ... test code ...
ensure
  SomeClass.define_singleton_method(:some_method, original)
```

## Struct-Based Fakes for Service Tests

Use `Struct` to build lightweight fakes for collaborator objects. Define method overrides inside the `do...end` block:

```ruby
FakeSession = Struct.new(:agent, :calls, keyword_init: true) do
  def ask(message)
    calls << [:ask, message]
    :response
  end
end
```

See `test/services/agent_runtime_test.rb` for a full example with a `FakeSession` that records all method calls.

## Job Testing

Include `ActiveJob::TestHelper` and switch to the test queue adapter in `setup`/`teardown`:

```ruby
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
```

Assertions:

```ruby
assert_enqueued_with(job: ChatStreamJob) { ... }
assert_enqueued_jobs 1, only: CompactionJob { ... }
assert_no_enqueued_jobs only: ChatStreamJob { ... }
ChatStreamJob.perform_now(session.id, "Hello", workspace_id: workspace.id)
```

## Controller Testing

Inherit from `ActionDispatch::IntegrationTest`. Pass `api_auth_headers` on every request:

```ruby
class Api::V1::SomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user, @workspace = create_user_with_workspace
  end

  test "returns success" do
    get "/api/v1/some_path", headers: api_auth_headers(user: @user, workspace: @workspace)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "expected", body["key"]
  end
end
```

## Multiple Assertions Pragma

When a single test legitimately needs multiple assertions (e.g. verifying a complex response shape), suppress the Rubocop warning with a file-level pragma:

```ruby
# rubocop:disable Minitest/MultipleAssertions
class SomeTest < ActiveSupport::TestCase
  # ...
end
# rubocop:enable Minitest/MultipleAssertions
```

## MUST Rules

- **MUST** use `create_user_with_workspace` + `with_current_workspace` for any test touching workspace-scoped models
- **MUST** use `SecureRandom.hex(4)` in slugs and emails to prevent parallel-worker uniqueness conflicts
- **MUST** restore stubbed methods in `ensure` blocks, never rely on test teardown alone
- **MUST** include `ActiveJob::TestHelper`, set `queue_adapter = :test` in setup, and clear jobs in teardown for any job test
- **MUST** keep `bin/test` hermetic and move any live provider checks into `test/llm_integration/`

## NEVER Rules

- **NEVER** use RSpec, FactoryBot, Mocha, or any other test/mock gem — Minitest + `define_singleton_method` only
- **NEVER** set `Current.user` or `Current.workspace` directly without restoring — always use `with_current_workspace`
- **NEVER** use hardcoded emails or slugs in tests that run in parallel — always suffix with `SecureRandom.hex(4)`
- **NEVER** leave stubs in place after a test — always restore the original method in `ensure`
- **NEVER** add live LLM tests to the default suite or use them inflationarily for behavior that hermetic tests already cover

# Rails Service Skill

Copy-paste templates for service objects. Services live in `app/services/`.

## When to Use

- Multi-step logic that coordinates 2+ models
- Operations that call external APIs or LLMs
- Business logic that needs testable isolation from the request cycle
- Anything that doesn't fit cleanly in a model callback

## Service Template

```ruby
# frozen_string_literal: true

# One-line doc: what this service does and why it exists.
class DoSomethingService
  # @param record [SomeModel]
  # @param user [User]
  def initialize(record:, user:)
    @record = record
    @user = user
  end

  # Performs the operation and returns a structured result hash.
  #
  # @return [Hash] with keys: success (Boolean), reason (String), data (Hash, optional)
  def call
    return { success: false, reason: "already_done" } if @record.done?

    result = do_the_work
    @record.update!(status: "done", result:)

    { success: true, reason: "ok", data: { result: } }
  rescue StandardError => e
    Rails.logger.error("[DoSomething] #{e.message}")
    { success: false, reason: "error: #{e.message}" }
  end

  private

  # @return [String]
  def do_the_work
    # ...
  end
end
```

Key conventions:
- Constructor injection — dependencies passed via `initialize`, not fetched inside methods
- Single public entry point: `call` for mutations, `build` for assembly, `compact!` for in-place updates
- Return a structured hash: `{ success:, reason:, data: }` — callers can pattern-match
- LLM calls belong in background jobs, not service objects called from the request cycle
- Naming: `VerbNounService` (e.g. `CompactSessionService`, `BuildContextService`)
- YARD on the class and `call` / `build`

## Test Template (Struct-based fakes)

```ruby
# frozen_string_literal: true

require "test_helper"

class DoSomethingServiceTest < ActiveSupport::TestCase
  # Lightweight fake: use Struct + method overrides, no mocking gems
  FakeRecord = Struct.new(:done, :status, :result, keyword_init: true) do
    def done? = done

    def update!(attrs)
      attrs.each { |k, v| send(:"#{k}=", v) }
    end
  end

  test "returns success hash and updates record" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      record = FakeRecord.new(done: false, status: nil, result: nil)
      result = DoSomethingService.new(record:, user:).call

      assert result[:success]
      assert_equal "ok", result[:reason]
      assert_equal "done", record.status
    end
  end

  test "returns already_done when record is already complete" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      record = FakeRecord.new(done: true, status: "done", result: nil)
      result = DoSomethingService.new(record:, user:).call

      assert_not result[:success]
      assert_equal "already_done", result[:reason]
    end
  end

  test "stubs a collaborator with define_singleton_method" do
    user, workspace = create_user_with_workspace
    original = ExternalThing.method(:call)
    calls = []

    ExternalThing.define_singleton_method(:call) { |*args| calls << args; "stub_result" }

    with_current_workspace(workspace, user:) do
      record = FakeRecord.new(done: false, status: nil, result: nil)
      DoSomethingService.new(record:, user:).call
      assert_equal 1, calls.size
    end
  ensure
    ExternalThing.define_singleton_method(:call, original)
  end
end
```

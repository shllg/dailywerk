# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class MemoryExtractionJobTest < ActiveSupport::TestCase
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

  test "stores extracted memories and updates the session checkpoint" do
    user, workspace = create_user_with_workspace
    original_constructor = MemoryExtractionService.method(:new)

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      session.messages.create!(role: "user", content: "Please remember that I dislike phone calls.")
      session.messages.create!(role: "assistant", content: "Understood. I will prefer asynchronous communication.")

      MemoryExtractionService.define_singleton_method(:new) do |session:|
        Struct.new(:memories) do
          def extract(_transcript)
            memories
          end
        end.new(
          [
            {
              content: "User prefers asynchronous communication over phone calls.",
              category: "preference",
              importance: 8,
              confidence: 0.9,
              visibility: "shared"
            }
          ]
        )
      end

      MemoryExtractionJob.perform_now(session.id, workspace_id: workspace.id)

      assert_equal 1, workspace.memory_entries.count
      assert_equal(
        "User prefers asynchronous communication over phone calls.",
        workspace.memory_entries.first.content
      )
      assert_predicate session.reload.context_data["memory_last_extracted_at"], :present?
    end
  ensure
    MemoryExtractionService.define_singleton_method(:new, original_constructor)
  end
end

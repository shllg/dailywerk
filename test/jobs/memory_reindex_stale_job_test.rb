# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class MemoryReindexStaleJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "re-enqueues embeddings for stale memories and archives" do
    user, workspace = create_user_with_workspace

    memory_entry = nil
    archive = nil

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "reindex-#{SecureRandom.hex(4)}",
        name: "Reindex",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)
      session.messages.create!(role: "user", content: "Need archive")
      session.update!(status: "archived")

      memory_entry = MemoryEntry.create!(
        workspace:,
        agent:,
        session:,
        category: "fact",
        content: "Remember to send the invoice.",
        source: "manual",
        importance: 6,
        confidence: 0.7
      )
      archive = ConversationArchive.create!(
        workspace:,
        agent:,
        session:,
        summary: "Invoice follow-up",
        ended_at: Time.current
      )
    end

    MemoryReindexStaleJob.perform_now

    assert_enqueued_with(
      job: GenerateEmbeddingJob,
      args: [ "MemoryEntry", memory_entry.id, { workspace_id: workspace.id } ]
    )
    assert_enqueued_with(
      job: GenerateEmbeddingJob,
      args: [ "ConversationArchive", archive.id, { workspace_id: workspace.id } ]
    )
  end
end

# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ConversationArchiveJobTest < ActiveSupport::TestCase
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

  test "creates an archive and enqueues an embedding job for archived sessions" do
    user, workspace = create_user_with_workspace

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "archiver-#{SecureRandom.hex(4)}",
        name: "Archiver",
        model_id: "gpt-5.4"
      )
      created_session = Session.resolve(agent:)
      created_session.messages.create!(role: "user", content: "Remember this launch checklist")
      created_session.messages.create!(role: "assistant", content: "I will keep the rollout sequence handy.")
      created_session.update!(
        status: "archived",
        message_count: 2,
        total_tokens: 88,
        started_at: 2.hours.ago,
        ended_at: 1.hour.ago
      )
      created_session
    end

    original_builder = ConversationArchiveBuilder.method(:new)
    fake_builder = Struct.new(:payload, keyword_init: true) do
      def build
        payload
      end
    end

    ConversationArchiveBuilder.define_singleton_method(:new) do |_actual_session|
      fake_builder.new(payload: { summary: "Launch archive", key_facts: [ "Ship checklist" ] })
    end

    ConversationArchiveJob.perform_now(session.id, workspace_id: workspace.id)

    Current.without_workspace_scoping do
      archive = ConversationArchive.find_by!(session:)

      assert_equal workspace.id, archive.workspace_id
      assert_equal session.agent_id, archive.agent_id
      assert_equal "Launch archive", archive.summary
      assert_equal [ "Ship checklist" ], archive.key_facts
      assert_equal 2, archive.message_count
      assert_equal 88, archive.total_tokens
      assert_equal "web", archive.metadata["gateway"]

      job = enqueued_jobs.last

      assert_equal GenerateEmbeddingJob, job[:job]
      assert_equal "ConversationArchive", job[:args][0]
      assert_equal archive.id, job[:args][1]
      assert_equal workspace.id, job[:args][2]["workspace_id"]
    end
  ensure
    ConversationArchiveBuilder.define_singleton_method(:new, original_builder)
  end

  test "skips active sessions" do
    user, workspace = create_user_with_workspace(
      email: "conversation-archive-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Conversation Archive"
    )

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "active-#{SecureRandom.hex(4)}",
        name: "Active",
        model_id: "gpt-5.4"
      )
      created_session = Session.resolve(agent:)
      created_session.messages.create!(role: "user", content: "Still working")
      created_session
    end

    ConversationArchiveJob.perform_now(session.id, workspace_id: workspace.id)

    Current.without_workspace_scoping do
      assert_nil ConversationArchive.find_by(session:)
    end
    assert_empty enqueued_jobs
  end
end
# rubocop:enable Minitest/MultipleAssertions

# frozen_string_literal: true

# Builds a durable archive record for an archived session.
class ConversationArchiveJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "conversation_archive_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(session_id, workspace_id:)
    session = Session.find(session_id)
    return unless session.status == "archived"
    return unless session.messages.where(role: %w[user assistant]).exists?

    payload = ConversationArchiveBuilder.new(session).build
    archive = ConversationArchive.find_or_initialize_by(session:)
    archive.assign_attributes(
      workspace: session.workspace,
      agent: session.agent,
      summary: payload[:summary].presence || "No archive summary available.",
      key_facts: payload[:key_facts],
      message_count: session.message_count,
      total_tokens: session.total_tokens,
      started_at: session.started_at,
      ended_at: session.ended_at,
      metadata: {
        "gateway" => session.gateway
      }
    )
    archive.save!

    GenerateEmbeddingJob.perform_later("ConversationArchive", archive.id, workspace_id: session.workspace_id)
  end
end

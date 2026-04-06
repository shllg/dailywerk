# frozen_string_literal: true

# Extracts durable memories from recently completed conversation turns.
class MemoryExtractionJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "memory_extraction_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(session_id, workspace_id:)
    session = Session.find(session_id)
    messages = pending_messages(session)
    return if messages.length < 2

    transcript = messages.map { |message| "[#{message.role}] #{message.content_for_context}" }.join("\n")
    return if transcript.length < 80

    extracted = MemoryExtractionService.new(session:).extract(transcript)
    return if extracted.empty?

    manager = MemoryManager.new(
      workspace: session.workspace,
      actor_agent: session.agent,
      session:
    )

    extracted.each do |memory|
      entry = manager.store(
        content: memory[:content],
        category: memory[:category],
        importance: memory[:importance],
        confidence: memory[:confidence],
        visibility: memory[:visibility],
        source: "extraction",
        metadata: {
          "extracted_from" => "session_messages"
        },
        source_message: messages.last
      )

      auto_promote(entry) if entry.staged? && memory[:importance] >= 8
    end

    session.merge_context_data!(
      "memory_last_extracted_at" => messages.last.created_at.iso8601
    )
  end

  private

  # Auto-promotes high-importance memories so they are visible immediately.
  #
  # @param entry [MemoryEntry]
  # @return [void]
  def auto_promote(entry)
    entry.update_columns(staged: false, promoted_at: Time.current)
  end

  # @param session [Session]
  # @return [Array<Message>]
  def pending_messages(session)
    checkpoint = extraction_checkpoint(session)
    scope = session.messages.where(role: %w[user assistant]).order(:created_at)
    scope = scope.where("created_at > ?", checkpoint) if checkpoint
    scope.last(12)
  end

  # @param session [Session]
  # @return [Time, nil]
  def extraction_checkpoint(session)
    value = session.context_data.to_h["memory_last_extracted_at"]
    Time.zone.parse(value) if value.present?
  rescue ArgumentError
    nil
  end
end

# frozen_string_literal: true

# Runs session compaction asynchronously.
class CompactionJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    perform_limit: 1,
    total_limit: 2,
    key: -> { "compaction_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(session_id, workspace_id:)
    session = Session.find(session_id)
    result = CompactionService.new(session).compact!

    Rails.logger.info(
      "[Compaction] session=#{session_id} " \
      "compacted=#{result[:compacted]} reason=#{result[:reason]} " \
      "messages_compacted=#{result[:messages_compacted] || 0}"
    )
  end
end

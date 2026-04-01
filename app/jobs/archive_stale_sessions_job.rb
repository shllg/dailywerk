# frozen_string_literal: true

# Archives abandoned sessions across all workspaces.
class ArchiveStaleSessionsJob < ApplicationJob
  STALE_THRESHOLD = 7.days

  queue_as :default

  # @return [void]
  def perform
    archived_count = 0

    Current.without_workspace_scoping do
      Session.stale(STALE_THRESHOLD.ago).find_each do |session|
        enqueue_compaction(session) if session.summary.blank? && session.messages.active.exists?
        session.archive!
        archived_count += 1
      end
    end

    Rails.logger.info("[ArchiveStale] Archived #{archived_count} sessions")
  end

  private

  # @param session [Session]
  # @return [void]
  def enqueue_compaction(session)
    CompactionJob.perform_later(session.id, workspace_id: session.workspace_id)
  end
end

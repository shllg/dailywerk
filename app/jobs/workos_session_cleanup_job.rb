# frozen_string_literal: true

# Deletes expired or revoked UserSession records older than 30 days.
#
# Cross-workspace cron job — user sessions are not workspace-scoped.
# Runs daily at 3am UTC via GoodJob cron.
class WorkosSessionCleanupJob < ApplicationJob
  RETENTION_PERIOD = 30.days

  queue_as :default

  # @return [void]
  def perform
    cutoff = RETENTION_PERIOD.ago

    deleted_count = UserSession
      .where("revoked_at < ? OR expires_at < ?", cutoff, cutoff)
      .delete_all

    Rails.logger.info "WorkosSessionCleanupJob: deleted #{deleted_count} stale sessions"
  end
end

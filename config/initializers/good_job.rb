Rails.application.configure do
  config.good_job.preserve_job_records = true
  config.good_job.retry_on_unhandled_error = false
  config.good_job.on_thread_error = ->(exception) { Rails.logger.error(exception) }
  config.good_job.cron = {
    profile_synthesis: {
      cron: "30 2 * * *",
      class: "ProfileSynthesisJob",
      description: "Rewrite synthesized user profiles from memories and archives"
    },
    memory_consolidation: {
      cron: "45 2 * * *",
      class: "MemoryConsolidationJob",
      description: "Promote staged memories, deduplicate, and apply recency decay"
    },
    archive_stale_sessions: {
      cron: "0 3 * * *",
      class: "ArchiveStaleSessionsJob",
      description: "Archive sessions inactive for more than 7 days"
    },
    memory_maintenance: {
      cron: "15 2 * * *",
      class: "MemoryMaintenanceJob",
      description: "Expire and deduplicate structured memories"
    },
    memory_reindex_stale: {
      cron: "*/20 * * * *",
      class: "MemoryReindexStaleJob",
      description: "Re-index memories and archives missing embeddings"
    },
    vault_s3_sync: {
      cron: "*/5 * * * *",
      class: "VaultS3SyncAllJob",
      description: "Sync all active vault changes to S3"
    },
    vault_reindex_stale: {
      cron: "*/30 * * * *",
      class: "VaultReindexStaleJob",
      description: "Re-index vault files missing embeddings"
    },
    vault_reconciliation: {
      cron: "0 */6 * * *",
      class: "VaultReconciliationJob",
      description: "Full disk-vs-DB consistency check"
    },
    workos_session_cleanup: {
      cron: "0 3 * * *",
      class: "WorkosSessionCleanupJob",
      description: "Delete expired/revoked auth sessions older than 30 days"
    }
  }
end

GoodJob::Engine.middleware.use ActionDispatch::Cookies
GoodJob::Engine.middleware.use ActionDispatch::Session::CookieStore, key: "_dailywerk_session"
GoodJob::Engine.middleware.use ActionDispatch::Flash
GoodJob::Engine.middleware.use Rack::MethodOverride

GoodJob::Engine.middleware.use Rack::Auth::Basic, "GoodJob" do |provided_username, provided_password|
  username = Rails.configuration.x.good_job.basic_auth_username.to_s
  password = Rails.configuration.x.good_job.basic_auth_password.to_s
  next false if username.blank? || password.blank?

  ActiveSupport::SecurityUtils.secure_compare(provided_username, username) &&
    ActiveSupport::SecurityUtils.secure_compare(provided_password, password)
end

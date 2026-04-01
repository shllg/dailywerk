Rails.application.configure do
  config.good_job.preserve_job_records = true
  config.good_job.retry_on_unhandled_error = false
  config.good_job.on_thread_error = ->(exception) { Rails.logger.error(exception) }
  config.good_job.cron = {
    archive_stale_sessions: {
      cron: "0 3 * * *",
      class: "ArchiveStaleSessionsJob",
      description: "Archive sessions inactive for more than 7 days"
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
    }
  }
end

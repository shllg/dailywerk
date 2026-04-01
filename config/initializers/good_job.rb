Rails.application.configure do
  config.good_job.preserve_job_records = true
  config.good_job.retry_on_unhandled_error = false
  config.good_job.on_thread_error = ->(exception) { Rails.logger.error(exception) }
  config.good_job.cron = {
    archive_stale_sessions: {
      cron: "0 3 * * *",
      class: "ArchiveStaleSessionsJob",
      description: "Archive sessions inactive for more than 7 days"
    }
  }
end

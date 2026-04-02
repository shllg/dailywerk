class ApplicationJob < ActiveJob::Base
  around_perform :log_job_execution

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private

  # @yield Runs the job and emits structured lifecycle logs.
  # @return [void]
  def log_job_execution
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Rails.logger.info(job_log_payload("job_start"))

    yield

    Rails.logger.info(job_log_payload("job_finish", duration_ms: elapsed_milliseconds(started_at)))
  rescue StandardError => error
    Rails.logger.error(
      job_log_payload(
        "job_error",
        duration_ms: elapsed_milliseconds(started_at),
        error_class: error.class.name,
        error_message: error.message
      )
    )
    raise
  end

  # @param started_at [Float]
  # @return [Float]
  def elapsed_milliseconds(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
  end

  # @param event [String]
  # @param extra [Hash]
  # @return [Hash]
  def job_log_payload(event, extra = {})
    {
      event:,
      job: self.class.name,
      job_id:,
      queue_name:
    }.merge(extra)
  end
end

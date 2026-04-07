class ApplicationJob < ActiveJob::Base
  around_perform :log_job_execution

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private

  # Runs a block with both `Current.workspace` and the PostgreSQL RLS session
  # variable set for a single workspace.
  #
  # @param workspace [Workspace]
  # @param user [User, nil]
  # @yield Executes within the workspace DB context.
  # @return [Object]
  def with_workspace_context(workspace, user: nil)
    previous_user = Current.user
    previous_workspace = Current.workspace
    connection = ActiveRecord::Base.connection
    previous_db_workspace_id = connection.select_value("SELECT current_setting('app.current_workspace_id', true)")

    Current.user = user
    Current.workspace = workspace
    connection.execute(
      "SET app.current_workspace_id = #{connection.quote(workspace.id)}"
    )

    yield
  ensure
    if workspace&.id.present?
      if previous_db_workspace_id.present?
        connection&.execute(
          "SET app.current_workspace_id = #{connection.quote(previous_db_workspace_id)}"
        )
      else
        connection&.execute("RESET app.current_workspace_id")
      end
    end
    Current.user = previous_user
    Current.workspace = previous_workspace
  end

  # Iterates all workspaces with RLS context set per workspace.
  #
  # @yieldparam workspace [Workspace]
  # @return [void]
  def each_workspace
    Workspace.find_each do |workspace|
      with_workspace_context(workspace) { yield workspace }
    end
  end

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

ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback :checkin, :before do
    raw_connection.exec("RESET app.current_workspace_id")
  rescue ActiveRecord::NoDatabaseError
    # `db:test:prepare` temporarily checks connections while the test database
    # is absent; suppress that expected reset failure.
  rescue StandardError => e
    Rails.logger.error("[RlsSafety] Failed to reset app.current_workspace_id: #{e.class}: #{e.message}")
  end
end

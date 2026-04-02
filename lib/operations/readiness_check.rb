# frozen_string_literal: true

module Operations
  # Checks whether the app is ready to receive traffic.
  class ReadinessCheck
    Result = Struct.new(:ready?, :checks, keyword_init: true)

    # @return [Result]
    def call
      checks = {
        database: database_check,
        valkey: valkey_check,
        migrations: migration_check
      }

      Result.new(ready?: checks.values.all? { |check| check[:ok] }, checks:)
    end

    private

    # @return [Hash]
    def database_check
      ActiveRecord::Base.connection.select_value("SELECT 1")
      { ok: true }
    rescue StandardError => error
      { ok: false, error: "#{error.class}: #{error.message}" }
    end

    # @return [Hash]
    def valkey_check
      client = Redis.new(
        url: ENV.fetch("VALKEY_URL") { ENV.fetch("REDIS_URL", "redis://localhost:6379/0") },
        connect_timeout: 1,
        read_timeout: 1,
        write_timeout: 1
      )

      response = client.ping
      { ok: response == "PONG" }
    rescue StandardError => error
      { ok: false, error: "#{error.class}: #{error.message}" }
    end

    # @return [Hash]
    def migration_check
      ActiveRecord::Migration.check_all_pending!
      { ok: true }
    rescue ActiveRecord::PendingMigrationError => error
      { ok: false, error: error.message }
    end
  end
end

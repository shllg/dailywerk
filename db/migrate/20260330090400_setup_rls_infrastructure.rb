class SetupRlsInfrastructure < ActiveRecord::Migration[8.1]
  APP_ROLE = "app_user".freeze

  def up
    app_password = connection.quote(ENV.fetch("DB_APP_PASSWORD", "dailywerk_app_password"))

    safety_assured do
      execute <<~SQL
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{APP_ROLE}') THEN
            CREATE ROLE #{APP_ROLE} LOGIN PASSWORD #{app_password};
          ELSE
            ALTER ROLE #{APP_ROLE} WITH LOGIN PASSWORD #{app_password};
          END IF;
        END
        $$;
      SQL

      execute "GRANT CONNECT ON DATABASE #{connection.quote_table_name(connection.current_database)} TO #{APP_ROLE}"
      execute "GRANT USAGE ON SCHEMA public TO #{APP_ROLE}"
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{APP_ROLE}"
      execute "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{APP_ROLE}"
      execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{APP_ROLE}"
      execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO #{APP_ROLE}"
    end
  end

  def down
    safety_assured do
      execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM #{APP_ROLE}"
      execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE USAGE, SELECT ON SEQUENCES FROM #{APP_ROLE}"
      execute "REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM #{APP_ROLE}"
      execute "REVOKE USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public FROM #{APP_ROLE}"
      execute "REVOKE USAGE ON SCHEMA public FROM #{APP_ROLE}"
      execute "REVOKE CONNECT ON DATABASE #{connection.quote_table_name(connection.current_database)} FROM #{APP_ROLE}"
      execute "DROP ROLE IF EXISTS #{APP_ROLE}"
    end
  end
end

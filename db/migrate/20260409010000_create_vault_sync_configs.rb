# frozen_string_literal: true

require_relative "../../lib/rls_migration_helpers"

# Creates the vault_sync_configs table for Obsidian Sync integration.
class CreateVaultSyncConfigs < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :vault_sync_configs, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.references :workspace, type: :uuid, null: false, foreign_key: true, index: true

      # Sync configuration
      t.string :sync_type, null: false, default: "obsidian"
      t.string :sync_mode, null: false, default: "bidirectional"

      # Encrypted credentials (stored as _enc suffix, encrypted by Rails)
      t.text :obsidian_email_enc
      t.text :obsidian_password_enc
      t.text :obsidian_encryption_password_enc

      # Remote vault identification
      t.string :obsidian_vault_name
      t.string :device_name

      # Process tracking
      t.string :process_status, null: false, default: "stopped"
      t.integer :process_pid
      t.string :process_host

      # Health tracking
      t.datetime :last_sync_at
      t.datetime :last_health_check_at
      t.integer :consecutive_failures, null: false, default: 0
      t.string :error_message

      # Additional settings
      t.jsonb :settings, null: false, default: {}

      t.timestamps

      # Index for health check queries
      t.index %i[process_status last_health_check_at]
    end

    safety_assured { enable_workspace_rls!(:vault_sync_configs) }
  end

  def down
    safety_assured { disable_workspace_rls!(:vault_sync_configs) }
    drop_table :vault_sync_configs
  end
end

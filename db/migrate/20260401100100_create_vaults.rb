require_relative "../../lib/rls_migration_helpers"

class CreateVaults < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :vaults, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.string :vault_type, null: false, default: "native"
      t.text :encryption_key_enc, null: false
      t.bigint :max_size_bytes, null: false, default: 2.gigabytes
      t.bigint :current_size_bytes, null: false, default: 0
      t.integer :file_count, null: false, default: 0
      t.string :status, null: false, default: "active"
      t.text :error_message
      t.jsonb :settings, null: false, default: {}
      t.timestamps

      t.index %i[workspace_id slug], unique: true
      t.index %i[workspace_id status]
    end

    safety_assured { enable_workspace_rls!(:vaults) }
  end

  def down
    safety_assured { disable_workspace_rls!(:vaults) }
    drop_table :vaults
  end
end

require_relative "../../lib/rls_migration_helpers"

class CreateVaultFiles < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :vault_files, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :path, null: false
      t.string :content_hash, null: false
      t.bigint :size_bytes, null: false, default: 0
      t.string :content_type
      t.string :file_type, null: false
      t.jsonb :frontmatter, null: false, default: {}
      t.string :tags, array: true, null: false, default: []
      t.string :title
      t.datetime :last_modified
      t.datetime :indexed_at
      t.datetime :synced_at
      t.timestamps

      t.index %i[vault_id path], unique: true
      t.index %i[workspace_id file_type]
      t.index :content_hash
      t.index :tags, using: :gin
    end

    safety_assured { enable_workspace_rls!(:vault_files) }
  end

  def down
    safety_assured { disable_workspace_rls!(:vault_files) }
    drop_table :vault_files
  end
end

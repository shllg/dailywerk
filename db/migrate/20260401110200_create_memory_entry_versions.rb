require_relative "../../lib/rls_migration_helpers"

class CreateMemoryEntryVersions < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :memory_entry_versions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :memory_entry, null: false, type: :uuid, foreign_key: true
      t.references :workspace, null: false, type: :uuid, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true
      t.references :editor_user, type: :uuid, foreign_key: { to_table: :users }
      t.references :editor_agent, type: :uuid, foreign_key: { to_table: :agents }
      t.string :action, null: false
      t.string :reason
      t.jsonb :snapshot, null: false, default: {}
      t.timestamps

      t.index %i[memory_entry_id created_at]
      t.index %i[workspace_id created_at]
    end

    safety_assured { enable_workspace_rls!(:memory_entry_versions) }
  end

  def down
    safety_assured { disable_workspace_rls!(:memory_entry_versions) }
    drop_table :memory_entry_versions
  end
end

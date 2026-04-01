require_relative "../../lib/rls_migration_helpers"

class CreateVaultLinks < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :vault_links, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :source,
                   type: :uuid,
                   null: false,
                   foreign_key: { to_table: :vault_files, on_delete: :cascade }
      t.references :target,
                   type: :uuid,
                   null: false,
                   foreign_key: { to_table: :vault_files, on_delete: :cascade }
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :link_type, null: false
      t.string :link_text
      t.text :context
      t.timestamps

      t.index %i[source_id target_id link_type], unique: true
      t.index %i[workspace_id link_type]
    end

    safety_assured { enable_workspace_rls!(:vault_links) }
  end

  def down
    safety_assured { disable_workspace_rls!(:vault_links) }
    drop_table :vault_links
  end
end

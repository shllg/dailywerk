require_relative "../../lib/rls_migration_helpers"

class CreateMemoryEntries < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :memory_entries, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, null: false, type: :uuid, foreign_key: true
      t.references :agent, type: :uuid, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true
      t.references :source_message, type: :uuid, foreign_key: { to_table: :messages }
      t.string :category, null: false, default: "fact"
      t.text :content, null: false
      t.string :source, null: false, default: "system"
      t.integer :importance, null: false, default: 5
      t.decimal :confidence, precision: 3, scale: 2, null: false, default: 0.7
      t.integer :access_count, null: false, default: 0
      t.datetime :last_accessed_at
      t.datetime :expires_at
      t.boolean :active, null: false, default: true
      t.string :fingerprint, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index %i[workspace_id active importance]
      t.index %i[workspace_id agent_id active], name: "index_memory_entries_on_scope"
      t.index %i[workspace_id fingerprint]
    end

    safety_assured do
      execute "ALTER TABLE memory_entries ADD COLUMN embedding vector(1536)"
      execute <<~SQL
        CREATE INDEX index_memory_entries_on_embedding
        ON memory_entries
        USING hnsw (embedding vector_cosine_ops);
      SQL
      enable_workspace_rls!(:memory_entries)
    end
  end

  def down
    safety_assured do
      disable_workspace_rls!(:memory_entries)
      execute "DROP INDEX IF EXISTS index_memory_entries_on_embedding"
    end

    drop_table :memory_entries
  end
end

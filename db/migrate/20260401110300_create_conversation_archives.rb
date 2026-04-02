require_relative "../../lib/rls_migration_helpers"

class CreateConversationArchives < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    safety_assured do
      execute "DROP INDEX IF EXISTS index_conversation_archives_on_session_id"
    end

    create_table :conversation_archives, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :session, null: false, type: :uuid, foreign_key: true
      t.references :workspace, null: false, type: :uuid, foreign_key: true
      t.references :agent, null: false, type: :uuid, foreign_key: true
      t.text :summary, null: false, default: ""
      t.jsonb :key_facts, null: false, default: []
      t.integer :message_count, null: false, default: 0
      t.integer :total_tokens, null: false, default: 0
      t.datetime :started_at
      t.datetime :ended_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index :session_id, unique: true, name: "idx_conversation_archives_session_unique"
      t.index %i[workspace_id agent_id ended_at], name: "index_conversation_archives_on_scope"
    end

    safety_assured do
      execute "ALTER TABLE conversation_archives ADD COLUMN embedding vector(1536)"
      execute <<~SQL
        CREATE INDEX index_conversation_archives_on_embedding
        ON conversation_archives
        USING hnsw (embedding vector_cosine_ops);
      SQL
      enable_workspace_rls!(:conversation_archives)
    end
  end

  def down
    safety_assured do
      disable_workspace_rls!(:conversation_archives)
      execute "DROP INDEX IF EXISTS index_conversation_archives_on_embedding"
    end

    drop_table :conversation_archives
  end
end

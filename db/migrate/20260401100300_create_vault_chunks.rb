require_relative "../../lib/rls_migration_helpers"

class CreateVaultChunks < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  TSVECTOR_FUNCTION_NAME = "vault_chunks_tsvector_update".freeze
  TSVECTOR_TRIGGER_NAME = "vault_chunks_tsvector_trigger".freeze

  def up
    create_table :vault_chunks, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault_file, type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :file_path, null: false
      t.integer :chunk_idx, null: false
      t.text :content, null: false
      t.string :heading_path
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index %i[vault_file_id chunk_idx], unique: true
      t.index %i[workspace_id file_path]
    end

    safety_assured do
      execute "ALTER TABLE vault_chunks ADD COLUMN tsv tsvector"
      execute "ALTER TABLE vault_chunks ADD COLUMN embedding vector(1536)"
      execute <<~SQL
        CREATE FUNCTION #{TSVECTOR_FUNCTION_NAME}()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          NEW.tsv := to_tsvector('english', coalesce(NEW.content, ''));
          RETURN NEW;
        END
        $$;
      SQL
      execute <<~SQL
        CREATE TRIGGER #{TSVECTOR_TRIGGER_NAME}
        BEFORE INSERT OR UPDATE OF content
        ON vault_chunks
        FOR EACH ROW
        EXECUTE FUNCTION #{TSVECTOR_FUNCTION_NAME}();
      SQL
      execute "CREATE INDEX index_vault_chunks_on_tsv ON vault_chunks USING gin (tsv)"
      execute <<~SQL
        CREATE INDEX index_vault_chunks_on_embedding
        ON vault_chunks
        USING hnsw (embedding vector_cosine_ops);
      SQL
      enable_workspace_rls!(:vault_chunks)
    end
  end

  def down
    safety_assured do
      disable_workspace_rls!(:vault_chunks)
      execute "DROP INDEX IF EXISTS index_vault_chunks_on_embedding"
      execute "DROP INDEX IF EXISTS index_vault_chunks_on_tsv"
      execute "DROP TRIGGER IF EXISTS #{TSVECTOR_TRIGGER_NAME} ON vault_chunks"
      execute "DROP FUNCTION IF EXISTS #{TSVECTOR_FUNCTION_NAME}()"
    end

    drop_table :vault_chunks
  end
end

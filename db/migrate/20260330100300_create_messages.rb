class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :session, type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :model,
                   type: :uuid,
                   foreign_key: { to_table: :ruby_llm_models }
      t.string :role, null: false
      t.text :content
      t.jsonb :content_raw
      t.text :thinking_text
      t.text :thinking_signature
      t.integer :thinking_tokens
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cached_tokens
      t.integer :cache_creation_tokens
      t.string :response_id
      t.timestamps

      t.index %i[session_id created_at]
      t.index :role
    end
  end
end

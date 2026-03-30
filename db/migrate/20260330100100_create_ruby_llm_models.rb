class CreateRubyLlmModels < ActiveRecord::Migration[8.1]
  def change
    create_table :ruby_llm_models, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.string :provider, null: false
      t.string :family
      t.datetime :model_created_at
      t.integer :context_window
      t.integer :max_output_tokens
      t.date :knowledge_cutoff
      t.jsonb :modalities, default: {}, null: false
      t.jsonb :capabilities, default: [], null: false
      t.jsonb :pricing, default: {}, null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps

      t.index %i[provider model_id], unique: true
      t.index :provider
      t.index :family
      t.index :capabilities, using: :gin
      t.index :modalities, using: :gin
    end
  end
end

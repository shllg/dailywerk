class CreateToolCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_calls, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :message, type: :uuid, null: false, foreign_key: true
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.text :thought_signature
      t.jsonb :arguments, default: {}, null: false
      t.timestamps

      t.index :tool_call_id, unique: true
      t.index :name
    end
  end
end

class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :slug, null: false
      t.string :name, null: false
      t.string :model_id, null: false, default: "gpt-5.4"
      t.text :instructions
      t.float :temperature, default: 0.7
      t.boolean :is_default, default: false, null: false
      t.boolean :active, default: true, null: false
      t.timestamps

      t.index %i[workspace_id slug], unique: true
      t.index %i[workspace_id is_default]
    end
  end
end

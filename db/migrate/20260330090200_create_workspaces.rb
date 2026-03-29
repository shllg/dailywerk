class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.string :name, null: false
      t.references :owner, null: false, type: :uuid, foreign_key: { to_table: :users }
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end
  end
end

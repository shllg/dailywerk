class CreateWorkspaceMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_memberships, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, null: false, type: :uuid, foreign_key: true
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.string :role, null: false, default: "owner"
      t.jsonb :abilities, null: false, default: {}
      t.timestamps
    end

    add_index :workspace_memberships, %i[workspace_id user_id], unique: true
  end
end

class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.string :email, null: false
      t.string :name, null: false
      t.string :workos_id
      t.string :status, null: false, default: "active"
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :workos_id, unique: true, where: "workos_id IS NOT NULL"
  end
end

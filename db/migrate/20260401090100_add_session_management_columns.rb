class AddSessionManagementColumns < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      change_table :sessions, bulk: true do |t|
        t.text :summary
        t.string :title
        t.jsonb :context_data, default: {}, null: false
        t.datetime :started_at
        t.datetime :ended_at
      end
    end

    safety_assured do
      execute <<~SQL
        UPDATE sessions
        SET started_at = created_at
        WHERE started_at IS NULL
      SQL
    end
  end

  def down
    safety_assured do
      remove_column :sessions, :ended_at
      remove_column :sessions, :started_at
      remove_column :sessions, :context_data
      remove_column :sessions, :title
      remove_column :sessions, :summary
    end
  end
end

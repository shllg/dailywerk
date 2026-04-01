class AddCompactionColumnsToMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :messages, :compacted, :boolean, default: false, null: false
    add_column :messages, :importance, :integer
    add_column :messages, :media_description, :text
    add_index :messages,
              :session_id,
              where: "compacted = false",
              name: "idx_messages_session_active",
              algorithm: :concurrently
  end

  def down
    remove_index :messages, name: "idx_messages_session_active", algorithm: :concurrently

    safety_assured do
      remove_column :messages, :media_description
      remove_column :messages, :importance
      remove_column :messages, :compacted
    end
  end
end

# frozen_string_literal: true

class AddStagedToMemoryEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    safety_assured do
      add_column :memory_entries, :staged, :boolean, default: true, null: false
      add_column :memory_entries, :promoted_at, :datetime
      add_column :memory_entries, :last_decay_at, :datetime
    end

    # Existing memories are already promoted (they were written before staging existed).
    reversible do |dir|
      dir.up do
        safety_assured do
          execute "UPDATE memory_entries SET staged = false, promoted_at = created_at"
        end
      end
    end

    add_index :memory_entries, %i[workspace_id staged importance],
              name: :index_memory_entries_on_workspace_staged_importance,
              algorithm: :concurrently
  end
end

class AddMemoryConfigToAgents < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      change_table :agents, bulk: true do |t|
        t.string :memory_isolation, null: false, default: "shared"
        t.jsonb :tool_names, null: false, default: %w[memory vault]
      end
    end
  end

  def down
    safety_assured do
      remove_column :agents, :tool_names
      remove_column :agents, :memory_isolation
    end
  end
end

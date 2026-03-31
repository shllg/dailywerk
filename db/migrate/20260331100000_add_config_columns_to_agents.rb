class AddConfigColumnsToAgents < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      change_table :agents, bulk: true do |t|
        t.text :soul
        t.jsonb :identity, default: {}
        t.string :provider
        t.jsonb :params, default: {}
        t.jsonb :thinking, default: {}
      end
    end
  end
end

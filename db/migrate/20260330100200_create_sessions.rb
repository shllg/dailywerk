require_relative "../../lib/rls_migration_helpers"

class CreateSessions < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :sessions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :agent, type: :uuid, null: false, foreign_key: true
      t.references :model,
                   type: :uuid,
                   foreign_key: { to_table: :ruby_llm_models }
      t.string :gateway, null: false, default: "web"
      t.string :status, null: false, default: "active"
      t.integer :message_count, default: 0, null: false
      t.integer :total_tokens, default: 0, null: false
      t.datetime :last_activity_at
      t.timestamps

      t.index %i[workspace_id agent_id gateway],
              unique: true,
              where: "status = 'active'",
              name: "idx_sessions_active_unique"
      t.index %i[workspace_id status]
    end

    safety_assured { enable_workspace_rls!(:sessions) }
  end

  def down
    safety_assured { disable_workspace_rls!(:sessions) }
    drop_table :sessions
  end
end

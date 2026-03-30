# Reusable RLS helpers for migrations.
#
# Include in any migration that creates a table requiring
# workspace-level row-level security.
#
# @example Direct workspace_id column
#   class CreateAgents < ActiveRecord::Migration[8.1]
#     include RlsMigrationHelpers
#     def up
#       create_table(:agents, ...) { ... }
#       safety_assured { enable_workspace_rls!(:agents) }
#     end
#     def down
#       safety_assured { disable_workspace_rls!(:agents) }
#       drop_table :agents
#     end
#   end
#
# @example Inherited via parent FK (no workspace_id on table)
#   class CreateToolCalls < ActiveRecord::Migration[8.1]
#     include RlsMigrationHelpers
#     def up
#       create_table(:tool_calls, ...) { ... }
#       safety_assured do
#         enable_parent_rls!(:tool_calls, parent_table: :messages, parent_fk: :message_id)
#       end
#     end
#   end
module RlsMigrationHelpers
  APP_ROLE = "app_user".freeze

  # Enable RLS on a table that has a direct +workspace_id+ column.
  def enable_workspace_rls!(table_name)
    execute "ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;"
    execute <<~SQL
      CREATE POLICY workspace_isolation ON #{table_name}
        FOR ALL TO #{APP_ROLE}
        USING (workspace_id::text = current_setting('app.current_workspace_id', true))
        WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
    SQL
  end

  # Disable RLS on a table that used +enable_workspace_rls!+.
  def disable_workspace_rls!(table_name)
    execute "DROP POLICY IF EXISTS workspace_isolation ON #{table_name};"
    execute "ALTER TABLE #{table_name} NO FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE #{table_name} DISABLE ROW LEVEL SECURITY;"
  end

  # Enable RLS on a table that inherits workspace scope through a parent FK.
  #
  # @param table_name [Symbol] the child table
  # @param parent_table [Symbol] the parent table (must have +workspace_id+)
  # @param parent_fk [Symbol] the FK column on the child pointing to the parent
  def enable_parent_rls!(table_name, parent_table:, parent_fk:)
    execute "ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;"
    execute <<~SQL
      CREATE POLICY workspace_isolation ON #{table_name}
        FOR ALL TO #{APP_ROLE}
        USING (
          EXISTS (
            SELECT 1
            FROM #{parent_table}
            WHERE #{parent_table}.id = #{table_name}.#{parent_fk}
              AND #{parent_table}.workspace_id::text = current_setting('app.current_workspace_id', true)
          )
        )
        WITH CHECK (
          EXISTS (
            SELECT 1
            FROM #{parent_table}
            WHERE #{parent_table}.id = #{table_name}.#{parent_fk}
              AND #{parent_table}.workspace_id::text = current_setting('app.current_workspace_id', true)
          )
        );
    SQL
  end

  # Disable RLS on a table that used +enable_parent_rls!+.
  def disable_parent_rls!(table_name)
    execute "DROP POLICY IF EXISTS workspace_isolation ON #{table_name};"
    execute "ALTER TABLE #{table_name} NO FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE #{table_name} DISABLE ROW LEVEL SECURITY;"
  end
end

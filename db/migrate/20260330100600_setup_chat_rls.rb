class SetupChatRls < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      enable_workspace_rls!(:agents)
      enable_workspace_rls!(:sessions)
      enable_workspace_rls!(:messages)
      enable_tool_call_rls!
    end
  end

  def down
    safety_assured do
      disable_tool_call_rls!
      disable_workspace_rls!(:messages)
      disable_workspace_rls!(:sessions)
      disable_workspace_rls!(:agents)
    end
  end

  private

  def enable_workspace_rls!(table_name)
    execute "ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;"
    execute <<~SQL
      CREATE POLICY workspace_isolation ON #{table_name}
        FOR ALL TO app_user
        USING (workspace_id::text = current_setting('app.current_workspace_id', true))
        WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
    SQL
  end

  def disable_workspace_rls!(table_name)
    execute "DROP POLICY IF EXISTS workspace_isolation ON #{table_name};"
    execute "ALTER TABLE #{table_name} NO FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE #{table_name} DISABLE ROW LEVEL SECURITY;"
  end

  def enable_tool_call_rls!
    execute "ALTER TABLE tool_calls ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE tool_calls FORCE ROW LEVEL SECURITY;"
    execute <<~SQL
      CREATE POLICY workspace_isolation ON tool_calls
        FOR ALL TO app_user
        USING (
          EXISTS (
            SELECT 1
            FROM messages
            WHERE messages.id = tool_calls.message_id
              AND messages.workspace_id::text = current_setting('app.current_workspace_id', true)
          )
        )
        WITH CHECK (
          EXISTS (
            SELECT 1
            FROM messages
            WHERE messages.id = tool_calls.message_id
              AND messages.workspace_id::text = current_setting('app.current_workspace_id', true)
          )
        );
    SQL
  end

  def disable_tool_call_rls!
    execute "DROP POLICY IF EXISTS workspace_isolation ON tool_calls;"
    execute "ALTER TABLE tool_calls NO FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE tool_calls DISABLE ROW LEVEL SECURITY;"
  end
end

class AddMessageToolCallForeignKey < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_foreign_key :messages, :tool_calls, validate: false
  end

  def down
    remove_foreign_key :messages, :tool_calls
  end
end

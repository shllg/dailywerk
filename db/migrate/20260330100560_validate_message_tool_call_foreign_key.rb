class ValidateMessageToolCallForeignKey < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    validate_foreign_key :messages, :tool_calls
  end
end

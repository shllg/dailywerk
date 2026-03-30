class AddToolCallReferenceToMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :messages, :tool_call, type: :uuid, index: { algorithm: :concurrently }
  end

  def down
    remove_reference :messages, :tool_call, index: true
  end
end

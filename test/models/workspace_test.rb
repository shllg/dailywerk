# frozen_string_literal: true

require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "destroy cascades sessions and messages" do
    user, workspace = create_user_with_workspace(
      email: "workspace-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Workspace #{SecureRandom.hex(4)}"
    )

    session = nil
    message = nil

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "agent-#{SecureRandom.hex(4)}",
        name: "Cleanup",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)
      message = session.messages.create!(role: "user", content: "Hello")
    end

    session_id = session.id
    message_id = message.id

    workspace.destroy!

    Current.without_workspace_scoping do
      assert_not Session.exists?(session_id)
      assert_not Message.exists?(message_id)
    end
  end
end

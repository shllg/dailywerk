# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ConversationArchiveTest < ActiveSupport::TestCase
  test "embedding_source_text joins the summary and key facts" do
    archive = ConversationArchive.new(
      summary: "Meeting recap",
      key_facts: [ "Ship Friday", "Owner: Sascha" ]
    )

    assert_equal "Meeting recap\nShip Friday\nOwner: Sascha", archive.embedding_source_text
  end

  test "validates that the session and agent belong to the same workspace" do
    user_one, workspace_one = create_user_with_workspace
    user_two, workspace_two = create_user_with_workspace(
      email: "conversation-archive-model-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    agent = nil
    session = nil

    with_current_workspace(workspace_one, user: user_one) do
      agent = Agent.create!(
        slug: "archive-model-#{SecureRandom.hex(4)}",
        name: "Archive Model",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)
    end

    with_current_workspace(workspace_two, user: user_two) do
      archive = ConversationArchive.new(
        workspace: workspace_two,
        session:,
        agent:,
        summary: "Cross-workspace archive"
      )

      assert_not archive.valid?
      assert_includes archive.errors[:session], "must belong to the current workspace"
      assert_includes archive.errors[:agent], "must belong to the current workspace"
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions

# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ProfileSynthesisServiceTest < ActiveSupport::TestCase
  test "writes a synthesized profile from memories and archives" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "profile-#{SecureRandom.hex(4)}",
        name: "Profile",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)
      session.update!(status: "archived")

      workspace.memory_entries.create!(
        agent:,
        session:,
        category: "preference",
        content: "User prefers concise answers.",
        source: "manual",
        importance: 8,
        confidence: 0.9,
        staged: false
      )
      workspace.conversation_archives.create!(
        session:,
        agent:,
        summary: "Discussed the launch timeline.",
        ended_at: 1.day.ago
      )

      with_stubbed_profile_chat("Structured user profile") do
        profile = ProfileSynthesisService.new(user:, workspace:).call

        assert_equal user.id, profile.user_id
        assert_equal workspace.id, profile.workspace_id
        assert_equal "Structured user profile", profile.synthesized_profile
        assert_not_nil profile.profile_synthesized_at
      end
    end
  end

  test "returns nil when there is no synthesis input" do
    user, workspace = create_user_with_workspace(
      email: "profile-synthesis-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Profile Synthesis"
    )

    with_current_workspace(workspace, user:) do
      assert_nil ProfileSynthesisService.new(user:, workspace:).call
      assert_nil UserProfile.find_by(user:, workspace:)
    end
  end

  private

  def with_stubbed_profile_chat(content)
    original_chat = RubyLLM.method(:chat)
    fake_chat = Object.new

    fake_chat.define_singleton_method(:with_temperature) do |_temperature|
      self
    end
    fake_chat.define_singleton_method(:ask) do |_prompt|
      Struct.new(:content).new(content)
    end

    RubyLLM.define_singleton_method(:chat) do |model:|
      raise "unexpected model" unless model == ProfileSynthesisService::DEFAULT_MODEL

      fake_chat
    end

    yield
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat)
  end
end
# rubocop:enable Minitest/MultipleAssertions

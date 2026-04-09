# frozen_string_literal: true

require "test_helper"

class ContextBuilderTest < ActiveSupport::TestCase
  test "build returns the prompt without summary" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        instructions: "Be concise."
      )
      session = Session.resolve(agent:)

      payload = with_empty_memory_context do
        ContextBuilder.new(session:).build
      end

      assert_includes payload[:system_prompt], "Be concise."
      assert_includes payload[:system_prompt], "## Knowledge Contract"
    end
  end

  test "build returns metadata defaults without summary" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        instructions: "Be concise."
      )
      session = Session.resolve(agent:)

      payload = with_empty_memory_context do
        ContextBuilder.new(session:).build
      end

      assert_equal 0, payload[:active_message_count]
      assert_equal 0, payload[:estimated_tokens]
    end
  end

  test "build includes the inherited summary" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      session.update!(summary: "Earlier discussion")

      payload = with_empty_memory_context do
        ContextBuilder.new(session:).build
      end

      assert_includes payload[:system_prompt], "## Previous Context\n\nEarlier discussion"
    end
  end

  test "build includes summarized bridge messages for a fresh session" do
    user, workspace = create_user_with_workspace
    original_batch_call = MessageSummarizer.method(:batch_call)

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      previous_session = Session.resolve(agent:)
      previous_session.messages.create!(role: "user", content: "Very long prior message")
      previous_session.messages.create!(role: "assistant", content: "Prior reply")
      previous_session.archive!

      current_session = Session.resolve(agent:)
      MessageSummarizer.define_singleton_method(:batch_call) do |texts, model:|
        Array(texts).map { |text| "#{model}: #{text.to_s.upcase}" }
      end

      payload = with_empty_memory_context do
        ContextBuilder.new(session: current_session).build
      end

      assert_includes payload[:system_prompt], "## Recent Messages (from previous session)"
      assert_includes payload[:system_prompt], "[user] gpt-5.4: VERY LONG PRIOR MESSAGE"
      assert_includes payload[:system_prompt], "[assistant] gpt-5.4: PRIOR REPLY"
    end
  ensure
    MessageSummarizer.define_singleton_method(:batch_call, original_batch_call)
  end

  test "build skips bridge messages once the current session has content" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      previous_session = Session.resolve(agent:)
      previous_session.messages.create!(role: "user", content: "Earlier message")
      previous_session.archive!

      current_session = Session.resolve(agent:)
      current_session.messages.create!(role: "user", content: "Current message")

      payload = with_empty_memory_context do
        ContextBuilder.new(session: current_session).build
      end

      assert_equal 1, payload[:active_message_count]
      assert_not_includes payload[:system_prompt], "## Recent Messages (from previous session)"
    end
  end

  test "build includes user profile when present" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      UserProfile.create!(
        user:,
        workspace:,
        synthesized_profile: "Prefers concise communication. Works on DailyWerk."
      )

      payload = with_empty_memory_context do
        ContextBuilder.new(session:).build
      end

      assert_includes payload[:system_prompt], "## About This User"
      assert_includes payload[:system_prompt], "Prefers concise communication."
    end
  end

  test "build includes available vaults section for a single vault" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      vault = Vault.create!(
        name: "Knowledge Base",
        slug: "knowledge-base-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active",
        file_count: 7
      )

      payload = with_empty_memory_context do
        ContextBuilder.new(session:).build
      end

      assert_includes payload[:system_prompt], "## Available Vaults"
      assert_includes payload[:system_prompt], "This workspace has one vault. Pass `vault_slug: null` to use it by default."
      assert_includes payload[:system_prompt], "**#{vault.name}** (slug: `#{vault.slug}`, type: native, files: 7)"
    end
  end

  test "build includes available vaults section for multiple vaults" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      Vault.create!(
        name: "Knowledge Base",
        slug: "knowledge-base-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active",
        file_count: 2
      )
      Vault.create!(
        name: "Obsidian Notes",
        slug: "obsidian-notes-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active",
        file_count: 9
      )

      payload = with_empty_memory_context do
        ContextBuilder.new(session:).build
      end

      assert_includes payload[:system_prompt], "This workspace has 2 vaults. You must pass `vault_slug` to target the correct vault."
      assert_includes payload[:system_prompt], "slug: `knowledge-base-"
      assert_includes payload[:system_prompt], "slug: `obsidian-notes-"
    end
  end

  test "build omits available vaults section when no vaults exist" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)

      payload = with_empty_memory_context do
        ContextBuilder.new(session:).build
      end

      assert_not_includes payload[:system_prompt], "## Available Vaults"
      assert_includes payload[:system_prompt], "- Vault: no vault is configured yet."
    end
  end

  test "build includes deterministic recap for a fresh session" do
    user, workspace = create_user_with_workspace
    original_batch_call = MessageSummarizer.method(:batch_call)

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      previous_session = Session.resolve(agent:)
      previous_session.messages.create!(role: "user", content: "Discuss billing migration.")
      previous_session.messages.create!(role: "assistant", content: "Sure, let me look at that.")
      previous_session.update!(summary: "Discussed billing migration strategy. Decided to use Stripe.")
      previous_session.archive!

      current_session = Session.resolve(agent:)

      MessageSummarizer.define_singleton_method(:batch_call) do |texts, model:|
        Array(texts).map { |text| text.to_s.upcase }
      end

      payload = with_empty_memory_context do
        ContextBuilder.new(session: current_session).build
      end

      assert_includes payload[:system_prompt], "Your last conversation with this user"
      assert_includes payload[:system_prompt], "Discussed billing migration strategy."
    end
  ensure
    MessageSummarizer.define_singleton_method(:batch_call, original_batch_call)
  end

  private

  def with_empty_memory_context
    original_new = MemoryRetrievalService.method(:new)
    fake_service = Object.new
    fake_service.define_singleton_method(:build_context) { { memories: [], archives: [] } }

    MemoryRetrievalService.define_singleton_method(:new) do |*_args, **_kwargs|
      fake_service
    end

    yield
  ensure
    MemoryRetrievalService.define_singleton_method(:new, original_new)
  end
end

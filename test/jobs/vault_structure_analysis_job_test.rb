# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultStructureAnalysisJobTest < ActiveSupport::TestCase
  setup do
    @user, @workspace = create_user_with_workspace
    @vault = with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Knowledge",
        slug: "analysis-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end
  end

  teardown do
    FileUtils.rm_rf(@vault.local_path) if @vault
  end

  test "writes an analysis file and generates a guide when one is missing" do
    file_service = VaultFileService.new(vault: @vault)
    file_service.write("notes/alpha.md", "# Alpha")
    file_service.write("projects/beta.md", "# Beta")

    with_stubbed_chat_response("Generated guide") do
      VaultStructureAnalysisJob.perform_now(@vault.id, workspace_id: @workspace.id)
    end

    analysis = file_service.read("_dailywerk/vault-analysis.md")

    assert_includes analysis, "Total files: 2"
    assert_includes analysis, "`notes`"
    assert_includes analysis, "`projects`"
    assert_equal "Generated guide", file_service.read("_dailywerk/vault-guide.md")
  end

  test "preserves an existing guide file" do
    file_service = VaultFileService.new(vault: @vault)
    file_service.write("notes/alpha.md", "# Alpha")
    file_service.write("_dailywerk/vault-guide.md", "Existing guide")
    llm_called = false

    original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) do |**_kwargs|
      llm_called = true
      raise "should not be called"
    end

    VaultStructureAnalysisJob.perform_now(@vault.id, workspace_id: @workspace.id)

    assert_equal "Existing guide", file_service.read("_dailywerk/vault-guide.md")
    refute llm_called
    assert_includes file_service.read("_dailywerk/vault-analysis.md"), "Total files: 2"
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat)
  end

  private

  def with_stubbed_chat_response(content)
    original_chat = RubyLLM.method(:chat)
    fake_response = Struct.new(:content).new(content)
    fake_chat = Object.new
    fake_chat.define_singleton_method(:with_temperature) do |_temperature|
      self
    end
    fake_chat.define_singleton_method(:ask) do |_prompt|
      fake_response
    end

    RubyLLM.define_singleton_method(:chat) do |**_kwargs|
      fake_chat
    end

    yield
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat)
  end
end
# rubocop:enable Minitest/MultipleAssertions

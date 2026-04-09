# frozen_string_literal: true

require_relative "agent_integration_test_case"

# End-to-end coverage for the vault-backed agent flow using a live LLM.
class VaultAgentIntegrationTest < AgentIntegrationTestCase
  FakeS3Service = Struct.new(:put_calls, :ensure_prefix_called, keyword_init: true) do
    def ensure_prefix!
      self.ensure_prefix_called = true
    end

    def put_object(path, content)
      put_calls << [ path, content ]
    end
  end

  test "agent reads a manual vault file and creates a new vault file" do
    user, workspace = create_user_with_workspace(
      email: "agent-integration-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Agent Integration"
    )
    agent = create_default_agent!(workspace:, user:)
    fake_s3 = FakeS3Service.new(put_calls: [], ensure_prefix_called: false)

    with_stubbed_s3_service(fake_s3) do
      vault = create_vault_via_api(user:, workspace:)
      clear_enqueued_jobs

      source_path = "notes/manual-#{SecureRandom.hex(4)}.md"
      source_marker = "ember-otter-#{SecureRandom.hex(4)}"
      VaultFileService.new(vault:).write(
        source_path,
        "# Launch Plan\n\nCodename: #{source_marker}\n"
      )

      session = with_current_workspace(workspace, user:) do
        Session.resolve(agent:)
      end

      read_message = perform_live_chat_turn(
        session:,
        workspace:,
        user:,
        content: "Use the vault tool to read #{source_path} and reply with only the codename."
      )

      read_tool_call = read_message.tool_calls.find_by(name: "vault")

      assert_not_nil read_tool_call
      assert_includes read_tool_call.result.content, source_marker

      clear_enqueued_jobs

      generated_path = "notes/generated-#{SecureRandom.hex(4)}.md"
      generated_marker = "agent-created-#{SecureRandom.hex(4)}"
      write_message = perform_live_chat_turn(
        session:,
        workspace:,
        user:,
        content: <<~PROMPT.strip
          Use the vault tool to create #{generated_path} with exactly this content:
          Status: #{generated_marker}

          Reply with only CREATED after the write succeeds.
        PROMPT
      )

      write_tool_call = write_message.tool_calls.find_by(name: "vault")

      assert_not_nil write_tool_call
      assert_includes write_tool_call.result.content, generated_path
      assert_includes write_tool_call.result.content, "written"

      perform_enqueued_jobs only: VaultFileChangedJob

      generated_file = VaultFileService.new(vault:).read(generated_path)

      assert_includes generated_file, generated_marker

      with_current_workspace(workspace, user:) do
        vault_file = vault.reload.vault_files.find_by(path: generated_path)

        assert_not_nil vault_file
        assert_equal "markdown", vault_file.file_type
      end
    end
  end

  private

  # @param workspace [Workspace]
  # @param user [User]
  # @return [Agent]
  def create_default_agent!(workspace:, user:)
    with_current_workspace(workspace, user:) do
      Agent.create!(
        slug: "main-#{SecureRandom.hex(4)}",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        is_default: true,
        tool_names: %w[memory vault],
        instructions: "Always use the vault tool for vault file reads and writes."
      )
    end
  end

  # @param user [User]
  # @param workspace [Workspace]
  # @return [Vault]
  def create_vault_via_api(user:, workspace:)
    post "/api/v1/vaults",
         params: { vault: { name: "Integration Vault", vault_type: "native" } },
         as: :json,
         headers: api_auth_headers(user:, workspace:)

    assert_response :created

    vault_id = JSON.parse(response.body).dig("vault", "id")

    with_current_workspace(workspace, user:) do
      Vault.find(vault_id)
    end
  end

  # @param session [Session]
  # @param workspace [Workspace]
  # @param user [User]
  # @param content [String]
  # @return [Message]
  def perform_live_chat_turn(session:, workspace:, user:, content:)
    with_disabled_memory_extraction do
      ChatStreamJob.perform_now(
        session.id,
        content,
        workspace_id: workspace.id,
        user_id: user.id
      )
    end

    with_current_workspace(workspace, user:) do
      session.messages.where(role: "assistant").order(created_at: :desc).first
    end
  end

  # @yield
  # @return [Object]
  def with_disabled_memory_extraction
    original_perform_later = MemoryExtractionJob.method(:perform_later)
    MemoryExtractionJob.define_singleton_method(:perform_later) do |_session_id, workspace_id:|
      { skipped: true, workspace_id: workspace_id }
    end

    yield
  ensure
    MemoryExtractionJob.define_singleton_method(:perform_later, original_perform_later)
  end

  # @param fake_s3 [FakeS3Service]
  # @yield
  # @return [Object]
  def with_stubbed_s3_service(fake_s3)
    original_constructor = VaultS3Service.method(:new)
    VaultS3Service.define_singleton_method(:new) do |_vault|
      fake_s3
    end

    yield
  ensure
    VaultS3Service.define_singleton_method(:new, original_constructor)
  end
end

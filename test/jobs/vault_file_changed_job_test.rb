# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class VaultFileChangedJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    @user, @workspace = create_user_with_workspace
    @vault = with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Knowledge",
        slug: "knowledge-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
    end
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    FileUtils.rm_rf(@vault.local_path) if @vault
  end

  # rubocop:disable Minitest/MultipleAssertions
  test "processes markdown into metadata, chunks, links, and embedding jobs" do
    file_service = VaultFileService.new(vault: @vault)
    target_content = <<~MARKDOWN
      # Target

      #{'T' * 140}
    MARKDOWN
    source_content = <<~MARKDOWN
      ---
      tags:
        - inbox
      ---

      # Source

      This note references [[target-note]] and includes enough content to create a chunk.
      #{'S' * 140}
    MARKDOWN

    file_service.write("target-note.md", target_content)
    file_service.write("source-note.md", source_content)

    VaultFileChangedJob.perform_now(@vault.id, "target-note.md", "updated", workspace_id: @vault.workspace_id)

    assert_enqueued_jobs 1, only: GenerateEmbeddingJob do
      VaultFileChangedJob.perform_now(@vault.id, "source-note.md", "updated", workspace_id: @vault.workspace_id)
    end

    with_current_workspace(@workspace, user: @user) do
      target_file = @vault.vault_files.find_by!(path: "target-note.md")
      source_file = @vault.vault_files.find_by!(path: "source-note.md")

      assert_equal "markdown", source_file.file_type
      assert_equal [ "inbox" ], source_file.tags
      assert_predicate source_file.vault_chunks, :exists?
      assert_equal target_file, source_file.outgoing_links.first.target
      assert_equal "wikilink", source_file.outgoing_links.first.link_type
    end
  end
  # rubocop:enable Minitest/MultipleAssertions
end

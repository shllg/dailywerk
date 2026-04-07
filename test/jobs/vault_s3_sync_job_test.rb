# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultS3SyncJobTest < ActiveSupport::TestCase
  FakeS3Service = Struct.new(:remote_paths, :put_calls, :delete_calls, :delete_prefix_called, keyword_init: true) do
    def put_object(path, content)
      put_calls << [ path, content ]
    end

    def list_relative_keys
      remote_paths
    end

    def delete_object(path)
      delete_calls << path
    end

    def delete_prefix!
      self.delete_prefix_called = true
    end
  end

  setup do
    @user, @workspace = create_user_with_workspace
    @vault = with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Knowledge",
        slug: "sync-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end
  end

  teardown do
    FileUtils.rm_rf(@vault.local_path) if @vault
  end

  test "uploads changed files, deletes removed ones, and refreshes metrics" do
    file_service = VaultFileService.new(vault: @vault)
    file_service.write("fresh.md", "# Fresh")
    file_service.write("changed.md", "# Changed")
    file_service.write("keep.md", "# Keep")

    with_current_workspace(@workspace, user: @user) do
      @vault.vault_files.create!(
        workspace: @workspace,
        path: "changed.md",
        content_hash: "old-hash",
        size_bytes: 20,
        file_type: "markdown",
        last_modified: 1.hour.ago,
        synced_at: 2.hours.ago
      )
      @vault.vault_files.create!(
        workspace: @workspace,
        path: "keep.md",
        content_hash: "keep-hash",
        size_bytes: 20,
        file_type: "markdown",
        last_modified: 2.hours.ago,
        synced_at: 1.hour.ago
      )
      @vault.vault_files.create!(
        workspace: @workspace,
        path: "stale-db.md",
        content_hash: "stale-hash",
        size_bytes: 20,
        file_type: "markdown"
      )
    end

    fake_s3 = FakeS3Service.new(
      remote_paths: [ ".keep", "stale-db.md", "remote-only.md" ],
      put_calls: [],
      delete_calls: [],
      delete_prefix_called: false
    )

    with_stubbed_s3_service(fake_s3) do
      VaultS3SyncJob.perform_now(@vault.id, workspace_id: @workspace.id)
    end

    with_current_workspace(@workspace, user: @user) do
      assert_equal 3, @vault.reload.file_count
      assert_equal "active", @vault.status
      assert_nil @vault.error_message
      assert_nil @vault.vault_files.find_by(path: "stale-db.md")
      assert_not_nil @vault.vault_files.find_by!(path: "changed.md").synced_at
    end

    assert_equal(
      [ [ "changed.md", "# Changed" ], [ "fresh.md", "# Fresh" ] ].sort,
      fake_s3.put_calls.sort
    )
    assert_equal %w[remote-only.md stale-db.md].sort, fake_s3.delete_calls.sort
  end

  test "marks the vault suspended when the local checkout exceeds the size limit" do
    file_service = VaultFileService.new(vault: @vault)
    file_service.write("large.md", "X" * 32)
    with_current_workspace(@workspace, user: @user) do
      @vault.update!(max_size_bytes: 16)
    end

    fake_s3 = FakeS3Service.new(
      remote_paths: [],
      put_calls: [],
      delete_calls: [],
      delete_prefix_called: false
    )

    with_stubbed_s3_service(fake_s3) do
      VaultS3SyncJob.perform_now(@vault.id, workspace_id: @workspace.id)
    end

    with_current_workspace(@workspace, user: @user) do
      assert_equal "suspended", @vault.reload.status
      assert_includes @vault.error_message, "Vault size exceeds"
    end
  end

  private

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
# rubocop:enable Minitest/MultipleAssertions

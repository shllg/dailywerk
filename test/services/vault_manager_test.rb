# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultManagerTest < ActiveSupport::TestCase
  FakeS3Service = Struct.new(:put_calls, :ensure_prefix_called, :delete_prefix_called, keyword_init: true) do
    def ensure_prefix!
      self.ensure_prefix_called = true
    end

    def put_object(path, content)
      put_calls << [ path, content ]
    end

    def delete_prefix!
      self.delete_prefix_called = true
    end
  end

  setup do
    @user, @workspace = create_user_with_workspace
    @manager = VaultManager.new(workspace: @workspace)
    @original_vault_local_base = Rails.configuration.x.vault_local_base
    @temp_local_base = Dir.mktmpdir("vault-manager")
    Rails.configuration.x.vault_local_base = @temp_local_base
  end

  teardown do
    Rails.configuration.x.vault_local_base = @original_vault_local_base
    FileUtils.rm_rf(@temp_local_base)
  end

  test "create seeds local files, syncs them, and refreshes metrics" do
    fake_s3 = FakeS3Service.new(
      put_calls: [],
      ensure_prefix_called: false,
      delete_prefix_called: false
    )

    with_stubbed_s3_service(fake_s3) do
      vault = @manager.create(name: "Knowledge Base")

      assert_equal "knowledge-base", vault.slug
      assert fake_s3.ensure_prefix_called
      assert_path_exists File.join(vault.local_path, "_dailywerk/README.md")
      assert_path_exists File.join(vault.local_path, "_dailywerk/vault-guide.md")
      assert_equal 2, vault.reload.file_count
      assert_operator vault.current_size_bytes, :>, 0
      assert_equal(
        [ "_dailywerk/README.md", "_dailywerk/vault-guide.md" ],
        fake_s3.put_calls.map(&:first).sort
      )
      assert_nil Current.workspace
    end
  end

  test "destroy removes the local checkout and remote prefix" do
    vault = nil

    with_current_workspace(@workspace, user: @user) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "destroy-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end
    FileUtils.mkdir_p(vault.local_path)
    File.write(File.join(vault.local_path, "note.md"), "# Note")

    fake_s3 = FakeS3Service.new(
      put_calls: [],
      ensure_prefix_called: false,
      delete_prefix_called: false
    )

    with_stubbed_s3_service(fake_s3) do
      @manager.destroy(vault)
    end

    assert fake_s3.delete_prefix_called
    assert_not File.exist?(vault.local_path)
    Current.without_workspace_scoping do
      assert_not Vault.exists?(vault.id)
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

# frozen_string_literal: true

require "test_helper"

class VaultSyncConfigTest < ActiveSupport::TestCase
  setup do
    @user, @workspace = create_user_with_workspace
    @vault = with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Test Vault",
        slug: "test-vault-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active"
      )
    end
  end

  test "creates successfully with required attributes" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        sync_mode: "bidirectional",
        obsidian_vault_name: "My Vault",
        device_name: "Test Device",
        process_status: "stopped"
      )
    end

    assert_predicate config, :persisted?
    assert_equal "obsidian", config.sync_type
    assert_equal "bidirectional", config.sync_mode
    assert_equal "stopped", config.process_status
  end

  test "validates sync_type inclusion" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.new(
        vault: @vault,
        workspace: @workspace,
        sync_type: "invalid",
        sync_mode: "bidirectional"
      )
    end

    assert_not config.valid?
    assert_includes config.errors[:sync_type], "is not included in the list"
  end

  test "validates sync_mode inclusion" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.new(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        sync_mode: "invalid"
      )
    end

    assert_not config.valid?
    assert_includes config.errors[:sync_mode], "is not included in the list"
  end

  test "validates process_status inclusion" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.new(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        process_status: "invalid"
      )
    end

    assert_not config.valid?
    assert_includes config.errors[:process_status], "is not included in the list"
  end

  test "validates vault_id uniqueness" do
    with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        sync_mode: "bidirectional",
        device_name: "Device 1"
      )

      config2 = VaultSyncConfig.new(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        device_name: "Device 2"
      )

      assert_not config2.valid?
      assert_includes config2.errors[:vault_id], "has already been taken"
    end
  end

  test "validates vault matches workspace" do
    other_workspace = Workspace.create!(
      name: "Other",
      owner: @user
    )

    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.new(
        vault: @vault,
        workspace: other_workspace,  # Mismatched workspace
        sync_type: "obsidian"
      )
    end

    assert_not config.valid?
    assert_includes config.errors[:vault], "must belong to the current workspace"
  end

  test "encrypts obsidian_email" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        obsidian_email_enc: "secret@example.com"
      )
    end

    # Raw database value should be encrypted
    raw_value = ActiveRecord::Base.connection.execute(
      "SELECT obsidian_email_enc FROM vault_sync_configs WHERE id = '#{config.id}'"
    ).first["obsidian_email_enc"]

    refute_equal "secret@example.com", raw_value
    assert raw_value.start_with?("{\"p\":") # ActiveRecord::Encryption format
  end

  test "encrypts obsidian_password" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        obsidian_password_enc: "secretpassword"
      )
    end

    raw_value = ActiveRecord::Base.connection.execute(
      "SELECT obsidian_password_enc FROM vault_sync_configs WHERE id = '#{config.id}'"
    ).first["obsidian_password_enc"]

    refute_equal "secretpassword", raw_value
  end

  test "should_run? returns true for running/starting" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.new(process_status: "running")
    end

    assert_predicate config, :should_run?

    config.process_status = "starting"

    assert_predicate config, :should_run?

    config.process_status = "stopped"

    assert_not_predicate config, :should_run?
  end

  test "failed_permanently? returns true after max failures" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.new(consecutive_failures: VaultSyncConfig::MAX_FAILURES)
    end

    assert_predicate config, :failed_permanently?

    config.consecutive_failures = VaultSyncConfig::MAX_FAILURES - 1

    assert_not_predicate config, :failed_permanently?
  end

  test "active_syncs scope includes running and starting" do
    with_current_workspace(@workspace, user: @user) do
      running = VaultSyncConfig.create!(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian",
        process_status: "running"
      )

      # Create another vault for stopped config
      vault2 = Vault.create!(
        name: "Vault 2",
        slug: "vault-2-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active"
      )

      stopped = VaultSyncConfig.create!(
        vault: vault2,
        workspace: @workspace,
        sync_type: "obsidian",
        process_status: "stopped"
      )

      results = VaultSyncConfig.active_syncs

      assert_includes results, running
      refute_includes results, stopped
    end
  end

  test "belongs to vault" do
    config = with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: @vault,
        workspace: @workspace,
        sync_type: "obsidian"
      )
    end

    assert_equal @vault.id, config.vault.id
  end
end

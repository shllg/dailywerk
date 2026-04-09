# frozen_string_literal: true

# Stores sync configuration for a vault (e.g., Obsidian Sync credentials).
class VaultSyncConfig < ApplicationRecord
  include WorkspaceScoped

  SYNC_TYPES = %w[obsidian none].freeze
  SYNC_MODES = %w[bidirectional pull_only mirror_remote].freeze
  # Process statuses:
  #   stopped       - No sync activity
  #   starting      - Process spawn in progress (continuous mode)
  #   running       - Continuous sync active (deprecated) or periodic sync in progress
  #   stopping      - SIGTERM sent, waiting for exit
  #   syncing       - Periodic one-shot sync currently running
  #   error         - Permanent failure (max retries exceeded)
  #   auth_required - Token invalid, user must re-authenticate
  #   deleting      - Marked for deletion, cleanup in progress
  PROCESS_STATUSES = %w[stopped starting running stopping syncing error auth_required deleting].freeze
  MAX_FAILURES = 5

  after_destroy :cleanup_config_directory

  belongs_to :vault, inverse_of: :sync_config

  # Encrypted credential fields (non-deterministic encryption)
  encrypts :obsidian_email_enc, deterministic: false
  encrypts :obsidian_password_enc, deterministic: false
  encrypts :obsidian_encryption_password_enc, deterministic: false

  validates :sync_type, inclusion: { in: SYNC_TYPES }
  validates :sync_mode, inclusion: { in: SYNC_MODES }
  validates :process_status, inclusion: { in: PROCESS_STATUSES }
  validates :vault_id, uniqueness: true

  validate :vault_matches_workspace

  # Active continuous sync processes (deprecated - replaced by periodic sync)
  scope :active_syncs, -> { where(process_status: %w[starting running stopping]) }
  # Configs that need health monitoring
  scope :needing_health_check, -> { where(process_status: %w[starting running stopping]) }
  # Configs that can perform periodic sync
  scope :available_for_sync, -> { where(process_status: %w[stopped error auth_required]) }

  # @return [Boolean] whether a continuous sync process should be running
  def should_run?
    process_status.in?(%w[starting running stopping])
  end

  # @return [Boolean] whether the sync has failed permanently
  def failed_permanently?
    consecutive_failures >= MAX_FAILURES
  end

  # @return [String, nil] the decrypted email for CLI use
  def obsidian_email
    obsidian_email_enc
  end

  # @return [String, nil] the decrypted password for CLI use
  def obsidian_password
    obsidian_password_enc
  end

  # @return [String, nil] the decrypted encryption password for CLI use
  def obsidian_encryption_password
    obsidian_encryption_password_enc
  end

  # @return [String] the base path for XDG config directories
  def config_base_path
    File.join(
      Rails.configuration.x.vault_local_base.presence || Vault::DEFAULT_LOCAL_BASE,
      workspace_id.to_s,
      "config",
      id.to_s
    )
  end

  private

  # @return [void]
  def vault_matches_workspace
    return if vault.blank? || workspace.blank?
    return if vault.workspace_id == workspace_id

    errors.add(:vault, "must belong to the current workspace")
  end

  # Cleans up the XDG config directory on destroy.
  # Uses the manager to ensure consistent cleanup logic.
  #
  # @return [void]
  def cleanup_config_directory
    # Skip if we're in a state where the manager can't be initialized
    return unless vault.present?

    manager = ObsidianSyncManager.new(self)
    manager.cleanup_config_directory!
  rescue StandardError => e
    Rails.logger.error "[VaultSyncConfig] Failed to cleanup config directory on destroy: #{e.message}"
    # Don't raise - we want destroy to succeed even if cleanup fails
  end
end

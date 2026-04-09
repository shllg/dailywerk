# frozen_string_literal: true

# Stores sync configuration for a vault (e.g., Obsidian Sync credentials).
class VaultSyncConfig < ApplicationRecord
  include WorkspaceScoped

  SYNC_TYPES = %w[obsidian none].freeze
  SYNC_MODES = %w[bidirectional pull_only mirror_remote].freeze
  PROCESS_STATUSES = %w[stopped starting running error crashed].freeze
  MAX_FAILURES = 5

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

  scope :active_syncs, -> { where(process_status: %w[starting running]) }
  scope :needing_health_check, -> { where(process_status: %w[starting running]) }

  # @return [Boolean] whether the sync should be running
  def should_run?
    process_status.in?(%w[starting running])
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

  private

  # @return [void]
  def vault_matches_workspace
    return if vault.blank? || workspace.blank?
    return if vault.workspace_id == workspace_id

    errors.add(:vault, "must belong to the current workspace")
  end
end

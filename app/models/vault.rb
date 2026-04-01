# frozen_string_literal: true

require "securerandom"

# Stores the workspace-scoped metadata for one knowledge vault.
class Vault < ApplicationRecord
  include WorkspaceScoped

  TYPES = %w[native obsidian].freeze
  STATUSES = %w[active syncing error suspended].freeze
  DEFAULT_LOCAL_BASE = Rails.root.join("tmp/workspaces").to_s

  encrypts :encryption_key_enc, deterministic: false

  has_many :vault_files, dependent: :destroy, inverse_of: :vault
  has_many :vault_chunks, through: :vault_files
  has_many :outgoing_vault_links, through: :vault_files, source: :outgoing_links
  has_many :incoming_vault_links, through: :vault_files, source: :incoming_links

  before_validation :ensure_encryption_key, on: :create

  validates :name, presence: true
  validates :slug,
            presence: true,
            format: { with: /\A[a-z0-9][a-z0-9-]*\z/ },
            uniqueness: { scope: :workspace_id }
  validates :vault_type, inclusion: { in: TYPES }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }

  # @return [String] the local checkout path for this vault
  def local_path
    File.join(
      Rails.configuration.x.vault_local_base.presence || DEFAULT_LOCAL_BASE,
      workspace_id.to_s,
      "vaults",
      slug
    )
  end

  # @return [String] the canonical S3 prefix for this vault
  def s3_prefix
    "workspaces/#{workspace_id}/vaults/#{slug}"
  end

  # @return [Boolean] whether the vault is over its configured size limit
  def over_limit?
    current_size_bytes.to_i >= max_size_bytes.to_i
  end

  # @return [String] the raw 32-byte SSE-C key derived from the stored hex key
  def sse_customer_key
    [ encryption_key_enc ].pack("H*")
  end

  private

  # @return [void]
  def ensure_encryption_key
    self.encryption_key_enc ||= SecureRandom.hex(32)
  end
end

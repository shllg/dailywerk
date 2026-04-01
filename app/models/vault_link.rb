# frozen_string_literal: true

# Stores one resolved link between two vault files.
class VaultLink < ApplicationRecord
  include WorkspaceScoped

  LINK_TYPES = %w[wikilink embed].freeze

  belongs_to :source, class_name: "VaultFile", inverse_of: :outgoing_links
  belongs_to :target, class_name: "VaultFile", inverse_of: :incoming_links

  validates :link_type, inclusion: { in: LINK_TYPES }
  validates :source_id, uniqueness: { scope: %i[target_id link_type] }
  validate :workspace_matches_linked_files

  private

  # @return [void]
  def workspace_matches_linked_files
    return if workspace.blank? || source.blank? || target.blank?
    return if source.workspace_id == workspace_id && target.workspace_id == workspace_id

    errors.add(:base, "source and target must belong to the current workspace")
  end
end

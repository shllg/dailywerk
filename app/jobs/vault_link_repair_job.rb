# frozen_string_literal: true

# Reprocesses files that linked to a moved target so stale link rows are dropped.
class VaultLinkRepairJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param vault_id [String]
  # @param old_path [String]
  # @param new_path [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(vault_id, old_path, new_path, workspace_id:)
    vault = Vault.find(vault_id)
    moved_file = vault.vault_files.find_by(path: new_path)
    return unless moved_file

    moved_file.incoming_links.includes(:source).find_each do |link|
      VaultFileChangedJob.perform_later(
        vault.id,
        link.source.path,
        "modify",
        workspace_id: workspace_id
      )
    end

    old_basename = File.basename(old_path.to_s, ".*")
    return if old_basename.blank?

    escaped_basename = ActiveRecord::Base.sanitize_sql_like(old_basename)

    vault.vault_chunks.where("content LIKE ?", "%[[#{escaped_basename}%").find_each do |chunk|
      VaultFileChangedJob.perform_later(
        vault.id,
        chunk.file_path,
        "modify",
        workspace_id: workspace_id
      )
    end
  end
end

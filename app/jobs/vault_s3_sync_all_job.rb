# frozen_string_literal: true

# Enqueues one sync job per active vault across all workspaces.
class VaultS3SyncAllJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    each_workspace do |_workspace|
      Vault.active.find_each do |vault|
        VaultS3SyncJob.perform_later(vault.id, workspace_id: vault.workspace_id)
      end
    end
  end
end

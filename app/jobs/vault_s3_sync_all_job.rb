# frozen_string_literal: true

# Enqueues one sync job per active vault across all workspaces.
class VaultS3SyncAllJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    Current.without_workspace_scoping do
      Vault.active.find_each do |vault|
        VaultS3SyncJob.perform_later(vault.id, workspace_id: vault.workspace_id)
      end
    end
  end
end

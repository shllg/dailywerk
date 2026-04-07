# frozen_string_literal: true

# Nightly job that rewrites synthesized user profiles from promoted memories
# and recent archives. Runs across all workspaces.
class ProfileSynthesisJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    each_workspace do |workspace|
      synthesize_for_workspace(workspace)
    end
  end

  private

  # @param workspace [Workspace]
  # @return [void]
  def synthesize_for_workspace(workspace)
    workspace.users.find_each do |user|
      with_workspace_context(workspace, user:) do
        ProfileSynthesisService.new(user:, workspace:).call
      end
    rescue StandardError => e
      Rails.logger.error(
        "[ProfileSynthesis] Failed for user #{user.id} in workspace #{workspace.id}: #{e.message}"
      )
    end
  end
end

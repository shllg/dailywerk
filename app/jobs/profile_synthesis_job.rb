# frozen_string_literal: true

# Nightly job that rewrites synthesized user profiles from promoted memories
# and recent archives. Runs across all workspaces.
class ProfileSynthesisJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    Current.without_workspace_scoping do
      Workspace.find_each do |workspace|
        synthesize_for_workspace(workspace)
      end
    end
  end

  private

  # @param workspace [Workspace]
  # @return [void]
  def synthesize_for_workspace(workspace)
    workspace.users.find_each do |user|
      Current.workspace = workspace
      Current.user = user
      ProfileSynthesisService.new(user:, workspace:).call
    rescue StandardError => e
      Rails.logger.error(
        "[ProfileSynthesis] Failed for user #{user.id} in workspace #{workspace.id}: #{e.message}"
      )
    ensure
      Current.reset
    end
  end
end

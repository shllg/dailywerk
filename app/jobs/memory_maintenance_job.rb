# frozen_string_literal: true

# Performs low-risk cleanup for structured memories across all workspaces.
class MemoryMaintenanceJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    expire_stale_memories
    deduplicate_exact_matches
  end

  private

  # @return [void]
  def expire_stale_memories
    Current.without_workspace_scoping do
      MemoryEntry.active.where.not(expires_at: nil).where("expires_at <= ?", Time.current).find_each do |entry|
        MemoryManager.new(workspace: entry.workspace, actor_agent: entry.agent, session: entry.session)
                     .deactivate(entry:, reason: "Expired during memory maintenance")
      end
    end
  end

  # @return [void]
  def deduplicate_exact_matches
    Current.without_workspace_scoping do
      duplicate_keys = MemoryEntry.active
                                  .group(:workspace_id, :agent_id, :fingerprint)
                                  .having("COUNT(*) > 1")
                                  .pluck(:workspace_id, :agent_id, :fingerprint)

      duplicate_keys.each do |workspace_id, agent_id, fingerprint|
        memories = MemoryEntry.where(
          workspace_id:,
          agent_id:,
          fingerprint:,
          active: true
        ).order(importance: :desc, updated_at: :desc)
        keeper = memories.first
        next unless keeper

        memories.where.not(id: keeper.id).find_each do |duplicate|
          MemoryManager.new(
            workspace: keeper.workspace,
            actor_agent: keeper.agent,
            session: keeper.session
          ).deactivate(entry: duplicate, reason: "Exact duplicate removed during maintenance")
        end
      end
    end
  end
end

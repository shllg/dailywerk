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
    each_workspace do |_workspace|
      MemoryEntry.active.where.not(expires_at: nil).where("expires_at <= ?", Time.current).find_each do |entry|
        MemoryManager.new(workspace: entry.workspace, actor_agent: entry.agent, session: entry.session)
                     .deactivate(entry:, reason: "Expired during memory maintenance")
      end
    end
  end

  # @return [void]
  def deduplicate_exact_matches
    each_workspace do |_workspace|
      duplicate_keys = MemoryEntry.active
                                  .group(:agent_id, :fingerprint)
                                  .having("COUNT(*) > 1")
                                  .pluck(:agent_id, :fingerprint)

      duplicate_keys.each do |agent_id, fingerprint|
        memories = MemoryEntry.where(
          agent_id:,
          fingerprint:,
          active: true
        ).order(importance: :desc, updated_at: :desc)
        keeper = memories.first
        next unless keeper

        memories.where.not(id: keeper.id).reorder(nil).find_each do |duplicate|
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

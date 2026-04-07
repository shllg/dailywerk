# frozen_string_literal: true

# Nightly job that promotes staged memories, deduplicates, resolves
# contradictions, and applies recency decay across all workspaces.
class MemoryConsolidationJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    each_workspace do |workspace|
      begin
        stats = MemoryConsolidationService.new(workspace:).call
        log_stats(workspace, stats)
      rescue StandardError => e
        Rails.logger.error(
          "[MemoryConsolidation] Failed for workspace #{workspace.id}: #{e.message}"
        )
      end
    end
  end

  private

  # @param workspace [Workspace]
  # @param stats [Hash]
  # @return [void]
  def log_stats(workspace, stats)
    return if stats.values.all?(&:zero?)

    Rails.logger.info(
      "[MemoryConsolidation] workspace=#{workspace.id} " \
      "promoted=#{stats[:promoted]} discarded=#{stats[:discarded]} " \
      "superseded=#{stats[:superseded]} decayed=#{stats[:decayed]} bumped=#{stats[:bumped]}"
    )
  end
end

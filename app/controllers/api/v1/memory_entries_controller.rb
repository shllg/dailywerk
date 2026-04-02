# frozen_string_literal: true

module Api
  module V1
    # Lists and edits structured memory entries for the active workspace.
    class MemoryEntriesController < ApplicationController
      include RequireWorkspaceAdmin

      # Returns the memory entries plus the available private-memory agent scopes.
      #
      # @return [void]
      def index
        render json: {
          entries: filtered_entries.map { |entry| memory_json(entry) },
          agents: Current.workspace.agents.active.order(:name).map { |agent| agent_json(agent) },
          categories: MemoryEntry::CATEGORIES
        }
      end

      # Returns one memory entry with its audit history.
      #
      # @return [void]
      def show
        entry = scoped_entries.find(params[:id])

        render json: {
          entry: memory_json(entry, include_versions: true)
        }
      end

      # Creates a new structured memory entry.
      #
      # @return [void]
      def create
        entry = manager.store(
          content: memory_entry_params[:content],
          category: memory_entry_params[:category],
          importance: memory_entry_params[:importance] || 5,
          confidence: memory_entry_params[:confidence] || 0.7,
          visibility: memory_entry_params[:visibility],
          agent: selected_agent,
          source: "manual",
          metadata: memory_entry_params[:metadata] || {},
          reason: memory_entry_params[:reason]
        )

        render json: { entry: memory_json(entry, include_versions: true) }, status: :created
      end

      # Updates an existing structured memory entry.
      #
      # @return [void]
      def update
        entry = scoped_entries.find(params[:id])
        updated_entry = manager.update(
          entry:,
          attributes: memory_entry_params.to_h.merge(agent: selected_agent),
          reason: memory_entry_params[:reason]
        )

        render json: { entry: memory_json(updated_entry, include_versions: true) }
      end

      # Soft-deletes a memory entry so it stops participating in recall.
      #
      # @return [void]
      def destroy
        entry = scoped_entries.find(params[:id])
        manager.deactivate(entry:, reason: params[:reason].presence || "Deleted from memory inspector")

        render json: { entry: memory_json(entry.reload, include_versions: true) }
      end

      private

      # @return [ActiveRecord::Relation]
      def filtered_entries
        entries = scoped_entries.includes(:agent, :session, :source_message, :versions).order(updated_at: :desc)
        entries = entries.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params[:active].present?
        entries = entries.where(category: params[:category]) if params[:category].present?

        case params[:scope]
        when "shared"
          entries = entries.where(agent_id: nil)
        when "private"
          entries = entries.where.not(agent_id: nil)
        end

        if params[:agent_id].present?
          entries = entries.where(agent_id: params[:agent_id])
        end

        if params[:query].present?
          query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:query].strip)}%"
          entries = entries.where("memory_entries.content ILIKE ?", query)
        end

        entries.limit(params.fetch(:limit, 100).to_i.clamp(1, 200))
      end

      # @return [ActiveRecord::Relation]
      def scoped_entries
        Current.workspace.memory_entries
      end

      # @return [MemoryManager]
      def manager
        @manager ||= MemoryManager.new(
          workspace: Current.workspace,
          actor_user: current_user
        )
      end

      # @return [Agent, nil]
      def selected_agent
        agent_id = memory_entry_params[:agent_id]
        return nil if agent_id.blank?

        Current.workspace.agents.active.find(agent_id)
      end

      # @return [ActionController::Parameters]
      def memory_entry_params
        params.require(:memory_entry).permit(
          :agent_id,
          :category,
          :confidence,
          :content,
          :expires_at,
          :importance,
          :reason,
          :source,
          :visibility,
          metadata: {}
        )
      end

      # @param agent [Agent]
      # @return [Hash]
      def agent_json(agent)
        {
          id: agent.id,
          name: agent.name,
          slug: agent.slug,
          memory_isolation: agent.memory_isolation
        }
      end

      # @param entry [MemoryEntry]
      # @param include_versions [Boolean]
      # @return [Hash]
      def memory_json(entry, include_versions: false)
        payload = {
          id: entry.id,
          category: entry.category,
          content: entry.content,
          source: entry.source,
          importance: entry.importance,
          confidence: entry.confidence.to_f.round(2),
          active: entry.active,
          visibility: entry.scope_label,
          fingerprint: entry.fingerprint,
          expires_at: entry.expires_at&.iso8601,
          access_count: entry.access_count,
          last_accessed_at: entry.last_accessed_at&.iso8601,
          updated_at: entry.updated_at.iso8601,
          metadata: entry.metadata || {},
          agent: entry.agent && agent_json(entry.agent),
          session_id: entry.session_id,
          source_message_id: entry.source_message_id
        }
        return payload unless include_versions

        payload.merge(
          versions: entry.versions.limit(10).map do |version|
            {
              id: version.id,
              action: version.action,
              reason: version.reason,
              created_at: version.created_at.iso8601,
              snapshot: version.snapshot
            }
          end
        )
      end
    end
  end
end

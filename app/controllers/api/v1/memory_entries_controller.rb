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
          entries: filtered_entries.map { |entry| MemoryEntrySerializer.summary(entry) },
          agents: Current.workspace.agents.active.order(:name).map { |agent| AgentSerializer.memory_scope(agent) },
          categories: MemoryEntry::CATEGORIES
        }
      end

      # Returns one memory entry with its audit history.
      #
      # @return [void]
      def show
        entry = scoped_entries.find(params[:id])

        render json: {
          entry: MemoryEntrySerializer.full(entry)
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

        render json: { entry: MemoryEntrySerializer.full(entry) }, status: :created
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

        render json: { entry: MemoryEntrySerializer.full(updated_entry) }
      end

      # Soft-deletes a memory entry so it stops participating in recall.
      #
      # @return [void]
      def destroy
        entry = scoped_entries.find(params[:id])
        manager.deactivate(entry:, reason: params[:reason].presence || "Deleted from memory inspector")

        render json: { entry: MemoryEntrySerializer.full(entry.reload) }
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
    end
  end
end

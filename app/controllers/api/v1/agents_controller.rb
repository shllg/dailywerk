# frozen_string_literal: true

module Api
  module V1
    # Manages the editable configuration for a workspace agent.
    class AgentsController < ApplicationController
      # Returns the current agent configuration plus factory defaults.
      #
      # @return [void]
      def show
        render json: response_payload
      end

      # Updates the editable agent fields.
      #
      # @return [void]
      def update
        if agent.update(agent_params)
          render json: response_payload
        else
          render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # Restores the agent's configurable fields to their defaults.
      #
      # @return [void]
      def reset
        AgentDefaults.reset!(agent)
        render json: response_payload
      end

      private

      # @return [Hash]
      def response_payload
        {
          agent: agent_json(agent),
          defaults: AgentDefaults.defaults
        }
      end

      # @return [Agent]
      def agent
        @agent ||= Current.workspace.agents.active.find(params[:id])
      end

      # @return [ActionController::Parameters]
      def agent_params
        params.require(:agent).permit(
          :name, :model_id, :memory_isolation, :provider, :temperature, :instructions, :soul,
          tool_names: [],
          identity: %w[persona tone constraints],
          thinking: %w[enabled budget_tokens]
        )
      end

      # @param agent [Agent]
      # @return [Hash]
      def agent_json(agent)
        {
          id: agent.id,
          slug: agent.slug,
          name: agent.name,
          model_id: agent.model_id,
          memory_isolation: agent.memory_isolation,
          provider: agent.provider,
          temperature: agent.temperature,
          instructions: agent.instructions,
          soul: agent.soul,
          identity: agent.identity || {},
          params: agent.params || {},
          thinking: agent.thinking || {},
          tool_names: agent.tool_names || [],
          is_default: agent.is_default,
          active: agent.active
        }
      end
    end
  end
end

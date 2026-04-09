# frozen_string_literal: true

module Api
  module V1
    # CRUD operations for workspace vaults.
    class VaultsController < ApplicationController
      include RequireWorkspaceAdmin

      rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

      # Lists all vaults for the current workspace.
      #
      # @return [void]
      def index
        vaults = Current.workspace.vaults.includes(:sync_config).order(updated_at: :desc)

        render json: {
          vaults: vaults.map { |vault| VaultSerializer.summary(vault) }
        }
      end

      # Shows a single vault with recent files and sync config.
      #
      # @return [void]
      def show
        vault = Current.workspace.vaults.includes(:sync_config).find(params[:id])

        render json: {
          vault: VaultSerializer.full(vault)
        }
      end

      # Creates a new vault for the workspace.
      #
      # @return [void]
      def create
        vault = manager.create(
          name: vault_params[:name],
          vault_type: vault_params[:vault_type] || "native"
        )

        render json: { vault: VaultSerializer.full(vault) }, status: :created
      end

      # Destroys a vault and its associated resources.
      # If the vault has a running sync, stops it first.
      #
      # @return [void]
      def destroy
        vault = find_vault(params[:id])

        # Check if there's a running sync that needs to be stopped first
        if vault.sync_config&.process_status.in?(%w[starting running])
          ObsidianSyncStopJob.perform_later(vault.sync_config.id, workspace_id: vault.workspace_id)
          render json: {
            message: "Vault deletion queued. Sync process is being stopped.",
            vault: VaultSerializer.summary(vault)
          }, status: :accepted
          return
        end

        manager.destroy(vault)

        head :no_content
      end

      private

      # @param id [String]
      # @return [Vault]
      def find_vault(id)
        Current.workspace.vaults.find(id)
      end

      # @return [VaultManager]
      def manager
        @manager ||= VaultManager.new(workspace: Current.workspace)
      end

      # @return [ActionController::Parameters]
      def vault_params
        params.require(:vault).permit(:name, :vault_type)
      end

      # @param error [ActiveRecord::RecordInvalid]
      # @return [void]
      def render_record_invalid(error)
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end
end

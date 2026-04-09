# frozen_string_literal: true

module Api
  module V1
    # Manages sync configuration for Obsidian and other external vault sources.
    # All sync lifecycle actions run in background jobs to avoid blocking.
    class VaultSyncConfigsController < ApplicationController
      include RequireWorkspaceAdmin

      rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

      # Creates or updates the sync config for a vault.
      # Credentials are encrypted via ActiveRecord::Encryption.
      #
      # @return [void]
      def update
        vault = find_vault(params[:vault_id])
        config = vault.sync_config || vault.build_sync_config(workspace: Current.workspace)

        # Assign credentials directly (they will be encrypted by the model)
        config.obsidian_email_enc = params.dig(:sync_config, :obsidian_email)
        config.obsidian_password_enc = params.dig(:sync_config, :obsidian_password)
        config.obsidian_encryption_password_enc = params.dig(:sync_config, :obsidian_encryption_password)

        config.assign_attributes(sync_config_params)

        config.save!

        render json: {
          sync_config: VaultSyncConfigSerializer.summary(config)
        }
      end

      # Removes the sync config and stops any running sync process.
      #
      # @return [void]
      def destroy
        vault = find_vault(params[:vault_id])
        config = vault.sync_config

        if config.nil?
          render json: { error: "Sync config not found" }, status: :not_found
          return
        end

        # Stop the sync process if running
        if config.process_status.in?(%w[starting running])
          ObsidianSyncStopJob.perform_later(config.id, workspace_id: vault.workspace_id)
        end

        config.destroy!

        head :no_content
      end

      # Enqueues the initial Obsidian sync setup (login, connect, first sync).
      # Returns 202 Accepted — the job runs in background.
      #
      # @return [void]
      def setup
        vault = find_vault(params[:vault_id])
        config = vault.sync_config

        if config.nil?
          render json: { error: "Sync config not found. Create one first." }, status: :not_found
          return
        end

        ObsidianSyncSetupJob.perform_later(config.id, workspace_id: vault.workspace_id)

        render json: {
          message: "Obsidian sync setup queued.",
          sync_config: VaultSyncConfigSerializer.summary(config)
        }, status: :accepted
      end

      # Enqueues start of continuous sync process.
      # Returns 202 Accepted — the job runs in background.
      #
      # @return [void]
      def start
        vault = find_vault(params[:vault_id])
        config = vault.sync_config

        if config.nil?
          render json: { error: "Sync config not found. Create one first." }, status: :not_found
          return
        end

        ObsidianSyncStartJob.perform_later(config.id, workspace_id: vault.workspace_id)

        render json: {
          message: "Obsidian sync start queued.",
          sync_config: VaultSyncConfigSerializer.summary(config)
        }, status: :accepted
      end

      # Enqueues stop of the sync process.
      # Returns 202 Accepted — the job runs in background.
      #
      # @return [void]
      def stop
        vault = find_vault(params[:vault_id])
        config = vault.sync_config

        if config.nil?
          render json: { error: "Sync config not found." }, status: :not_found
          return
        end

        ObsidianSyncStopJob.perform_later(config.id, workspace_id: vault.workspace_id)

        render json: {
          message: "Obsidian sync stop queued.",
          sync_config: VaultSyncConfigSerializer.summary(config)
        }, status: :accepted
      end

      private

      # @param vault_id [String]
      # @return [Vault]
      def find_vault(vault_id)
        Current.workspace.vaults.includes(:sync_config).find(vault_id)
      end

      # @return [ActionController::Parameters]
      def sync_config_params
        params.require(:sync_config).permit(
          :sync_type,
          :sync_mode,
          :obsidian_vault_name,
          :device_name
        )
      end

      # @param error [ActiveRecord::RecordInvalid]
      # @return [void]
      def render_record_invalid(error)
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end
end

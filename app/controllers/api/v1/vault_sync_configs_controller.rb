# frozen_string_literal: true

module Api
  module V1
    # Manages sync configuration for Obsidian and other external vault sources.
    # NOTE: Full implementation in Phase 2. Currently returns 501 Not Implemented.
    class VaultSyncConfigsController < ApplicationController
      include RequireWorkspaceAdmin

      # Returns 501 Not Implemented — Phase 2 adds VaultSyncConfig model and jobs.
      #
      # @return [void]
      def update
        render_not_implemented
      end

      # Returns 501 Not Implemented.
      #
      # @return [void]
      def destroy
        render_not_implemented
      end

      # Returns 501 Not Implemented.
      #
      # @return [void]
      def setup
        render_not_implemented
      end

      # Returns 501 Not Implemented.
      #
      # @return [void]
      def start
        render_not_implemented
      end

      # Returns 501 Not Implemented.
      #
      # @return [void]
      def stop
        render_not_implemented
      end

      private

      # @return [void]
      def render_not_implemented
        render json: {
          error: "Not Implemented",
          message: "Obsidian Sync support is coming in Phase 2."
        }, status: :not_implemented
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    # Issues a temporary dev-only API session token.
    class SessionsController < ApplicationController
      # ============================================================
      # TEMPORARY: Development-only fake session controller.
      # This controller will be removed when WorkOS is integrated.
      #
      # TODO: [WorkOS] Replace this with a WorkOS callback controller
      # and a service that finds or creates the user from WorkOS.
      # ============================================================
      skip_authentication!

      before_action :require_development_environment!

      # Creates a signed token for a local development user.
      #
      # @return [void]
      def create
        email = normalized_email(session_params[:email])
        user = User.active.find_by(email:)
        return render json: { error: "User not found" }, status: :unauthorized unless user

        workspace = user.default_workspace
        unless workspace
          return render json: { error: "Workspace not found" }, status: :unprocessable_entity
        end

        render json: {
          token: issue_token(user:, workspace:),
          user: {
            id: user.id,
            email: user.email,
            name: user.name
          },
          workspace: {
            id: workspace.id,
            name: workspace.name
          }
        }
      end

      private

      # @return [ActionController::Parameters] the allowed session params
      def session_params
        params.require(:session).permit(:email)
      end

      # Blocks the fake session endpoint outside local development and test.
      #
      # @return [void]
      def require_development_environment!
        return if Rails.env.development? || Rails.env.test?

        head :not_found
      end

      # @param email [String, nil]
      # @return [String] a normalized email address
      def normalized_email(email)
        email.to_s.strip.downcase
      end
    end
  end
end

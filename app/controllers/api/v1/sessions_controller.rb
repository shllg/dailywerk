# frozen_string_literal: true

module Api
  module V1
    # Issues a temporary dev-only API session token.
    #
    # This controller remains permanently for local development.
    # In production, authentication goes through WorkOS via
    # Api::V1::AuthController and Auth::CallbacksController.
    class SessionsController < ApplicationController
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
          user: UserSerializer.summary(user),
          workspace: WorkspaceSerializer.summary(workspace)
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

      # Builds a signed API session token for the user and workspace.
      #
      # @param user [User]
      # @param workspace [Workspace]
      # @param expires_in [ActiveSupport::Duration]
      # @return [String]
      def issue_token(user:, workspace:, expires_in: 12.hours)
        session_token_verifier.generate(
          { user_id: user.id, workspace_id: workspace.id },
          purpose: :api_session,
          expires_in:
        )
      end
    end
  end
end

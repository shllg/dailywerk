# frozen_string_literal: true

# Authenticates API requests and loads workspace context.
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_request!
    around_action :with_rls_context
  end

  class_methods do
    # Skips auth and RLS setup for selected actions.
    #
    # @param actions [Array<Symbol>]
    # @return [void]
    def skip_authentication!(*actions)
      if actions.any?
        skip_before_action :authenticate_request!, only: actions
        skip_around_action :with_rls_context, only: actions
      else
        skip_before_action :authenticate_request!
        skip_around_action :with_rls_context
      end
    end
  end

  private

  # @return [User, nil] the authenticated user for this request
  def current_user
    @current_user
  end

  # @return [Workspace, nil] the authenticated workspace for this request
  def current_workspace
    @current_workspace
  end

  # Verifies the Bearer token and loads Current.user and Current.workspace.
  #
  # @return [void]
  def authenticate_request!
    return if @current_user

    token = bearer_token
    return render_unauthorized unless token.present?

    payload = verify_token(token)
    return render_unauthorized unless payload.is_a?(Hash)

    user = User.active.find_by(id: payload["user_id"] || payload[:user_id])
    return render_unauthorized unless user

    workspace = resolve_workspace_for(user:, payload:)
    return render_unauthorized unless workspace

    @current_user = user
    @current_workspace = workspace
    Current.user = user
    Current.workspace = workspace
  end

  # Sets the PostgreSQL workspace variable for the request.
  #
  # @yield Runs the controller action inside the workspace DB context.
  # @return [Object, nil] the block result
  def with_rls_context
    authenticate_request! unless @current_user || performed?
    return if performed?

    workspace_id = current_workspace&.id || Current.workspace&.id
    if workspace_id.present?
      connection = ActiveRecord::Base.connection
      connection.execute(
        "SET app.current_workspace_id = #{connection.quote(workspace_id)}"
      )
    end

    yield
  ensure
    if workspace_id.present?
      ActiveRecord::Base.connection.execute("RESET app.current_workspace_id")
    end
  end

  # @return [String, nil] the Bearer token from the Authorization header
  def bearer_token
    request.authorization.to_s[/\ABearer (.+)\z/, 1]
  end

  # Picks the workspace named in the token, or falls back to the default one.
  #
  # @param user [User]
  # @param payload [Hash]
  # @return [Workspace, nil]
  def resolve_workspace_for(user:, payload:)
    workspace_id = payload["workspace_id"] || payload[:workspace_id]
    return user.default_workspace unless workspace_id.present?

    user.workspaces.find_by(id: workspace_id) || user.default_workspace
  end

  # TODO: [WorkOS] Replace this verifier with WorkOS JWT validation.
  # Everything else in this concern should remain the same.
  #
  # @param token [String]
  # @return [Hash, nil] the verified token payload
  def verify_token(token)
    session_token_verifier.verified(token, purpose: :api_session)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
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

  # @return [ActiveSupport::MessageVerifier]
  def session_token_verifier
    Rails.application.message_verifier(:api_session)
  end

  # Renders a consistent auth failure payload.
  #
  # @return [void]
  def render_unauthorized
    render json: { error: "Unauthorized" }, status: :unauthorized
  end
end

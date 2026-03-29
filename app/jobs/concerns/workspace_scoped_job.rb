# frozen_string_literal: true

# Sets Current.workspace and the PostgreSQL workspace variable for a job.
module WorkspaceScopedJob
  extend ActiveSupport::Concern

  included do
    around_perform :set_workspace_context
  end

  private

  # Runs the job inside the workspace passed in its keyword arguments.
  #
  # @yield Executes the job with workspace context loaded.
  # @return [Object] the block result
  def set_workspace_context
    workspace_id = extract_keyword_argument(:workspace_id)
    user_id = extract_keyword_argument(:user_id)

    raise ArgumentError, "#{self.class.name} requires workspace_id:" unless workspace_id.present?

    previous_user = Current.user
    previous_workspace = Current.workspace
    connection = ActiveRecord::Base.connection

    Current.user = User.find_by(id: user_id) if user_id.present?
    Current.workspace = Workspace.find(workspace_id)
    connection.execute(
      "SET app.current_workspace_id = #{connection.quote(Current.workspace.id)}"
    )

    yield
  ensure
    connection&.execute("RESET app.current_workspace_id") if workspace_id.present?
    Current.user = previous_user
    Current.workspace = previous_workspace
  end

  # Reads a keyword argument from Active Job's serialized arguments.
  #
  # @param key [Symbol]
  # @return [Object, nil]
  def extract_keyword_argument(key)
    options = arguments.last
    return unless options.is_a?(Hash)

    options[key] || options[key.to_s]
  end
end

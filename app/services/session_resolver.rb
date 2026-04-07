# frozen_string_literal: true

# Resolves the active session for an agent, rotating stale sessions when needed.
class SessionResolver
  # @param agent [Agent]
  # @param gateway [String]
  # @param workspace [Workspace, nil]
  # @return [Session]
  def self.call(agent:, gateway: "web", workspace: Current.workspace)
    new(agent:, gateway:, workspace:).call
  end

  # @param agent [Agent]
  # @param gateway [String]
  # @param workspace [Workspace, nil]
  def initialize(agent:, gateway:, workspace:)
    @agent = agent
    @gateway = gateway
    @workspace = workspace
  end

  # Finds or creates the active session for the current workspace.
  #
  # @return [Session]
  def call
    raise ArgumentError, "Current.workspace must be set" unless @workspace

    @agent.with_lock do
      session = find_active_session
      previous_summary = nil

      if session&.stale?
        previous_summary = session.summary.presence
        session.archive!
        session = nil
      end

      session ||= create_new_session(inherited_summary: previous_summary)
      ensure_model!(session)
    end
  end

  private

  # @return [Session, nil]
  def find_active_session
    Session.active.find_by(agent: @agent, workspace: @workspace, gateway: @gateway)
  end

  # @param inherited_summary [String, nil]
  # @return [Session]
  def create_new_session(inherited_summary:)
    provider = @agent.resolved_provider || AgentRuntime::DEFAULT_PROVIDER

    Session.create_or_find_by!(
      agent: @agent,
      workspace: @workspace,
      gateway: @gateway,
      status: "active"
    ) do |session|
      timestamp = Time.current
      session.last_activity_at = timestamp
      session.started_at = timestamp
      session.summary = inherited_summary.presence
      session.model = model_record_for(@agent.model_id, provider:)
    end
  end

  # @param session [Session]
  # @return [Session]
  def ensure_model!(session)
    return session if session.model.present?

    provider = @agent.resolved_provider || AgentRuntime::DEFAULT_PROVIDER
    session.update!(model: model_record_for(@agent.model_id, provider:))
    session
  end

  # @param model_id [String]
  # @param provider [String, Symbol]
  # @return [RubyLLM::ModelRecord]
  def model_record_for(model_id, provider:)
    RubyLLM::ModelRecord.find_or_create_by!(
      model_id:,
      provider: provider.to_s
    ) do |model|
      model.name = model_id
      model.capabilities = []
      model.modalities = {}
      model.pricing = {}
      model.metadata = {}
    end
  end
end

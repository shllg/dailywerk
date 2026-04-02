# frozen_string_literal: true

# Persists one active conversation per workspace, agent, and gateway.
class Session < ApplicationRecord
  include WorkspaceScoped

  # Fallback for models that have not been loaded into ruby_llm's registry yet.
  DEFAULT_CONTEXT_WINDOW_SIZE = 128_000
  # Time-based rotation keeps "one chat per agent" usable without letting a
  # single session grow forever. Agents can override this per use case.
  DEFAULT_SESSION_TIMEOUT_HOURS = 4

  # ruby_llm rebuilds chat state from this association on every turn. Pointing it
  # at `context_messages` lets us keep the full audit trail in `messages` while
  # only replaying the active, non-compacted window back to the model.
  acts_as_chat messages: :context_messages,
               message_class: "Message",
               model_class: "RubyLLM::ModelRecord"

  belongs_to :agent
  has_one :conversation_archive, dependent: :destroy, inverse_of: :session
  has_many :context_messages,
           -> { active.order(:created_at) },
           class_name: "Message",
           foreign_key: :session_id,
           inverse_of: :session
  has_many :memory_entries, dependent: :nullify, inverse_of: :session
  has_many :messages,
           -> { order(:created_at) },
           dependent: :destroy,
           inverse_of: :session

  validates :gateway, presence: true
  validates :status, presence: true, inclusion: { in: %w[active archived] }
  validate :agent_belongs_to_workspace

  scope :active, -> { where(status: "active") }
  scope :stale, ->(before_time) { active.where("last_activity_at < ?", before_time) }

  after_commit :enqueue_conversation_archive_job, on: :update, if: :archived_now_with_messages?

  # Finds or creates the active session for the current workspace.
  #
  # @param agent [Agent]
  # @param gateway [String]
  # @return [Session]
  def self.resolve(agent:, gateway: "web")
    workspace = Current.workspace
    raise ArgumentError, "Current.workspace must be set" unless workspace

    session = find_active_session(agent:, workspace:, gateway:)
    previous_summary = nil

    if session&.stale?
      previous_summary = session.summary.presence
      session.archive!
      session = nil
    end

    session ||= create_new_session(
      agent:,
      workspace:,
      gateway:,
      inherited_summary: previous_summary
    )

    return session if session.model.present?

    provider = agent.resolved_provider || AgentRuntime::DEFAULT_PROVIDER
    session.update!(model: model_record_for(agent.model_id, provider:))
    session
  end

  # Returns the latest persisted context token count for active messages.
  #
  # @return [Integer]
  def active_context_tokens
    last_message = context_messages.where.not(role: "system").order(:created_at).last
    return 0 unless last_message

    last_message.input_tokens.to_i + last_message.output_tokens.to_i
  end

  # Estimates active context usage without a provider tokenization call.
  # This deliberately uses a cheap chars/4 heuristic so the request path can
  # decide whether to enqueue compaction without another network round trip.
  #
  # @return [Integer]
  def estimated_context_tokens
    total_characters = context_messages.sum(
      "coalesce(length(media_description), length(content), 0)"
    )
    (total_characters / 4.0).ceil
  end

  # Returns the provider context window for the current model.
  #
  # @return [Integer]
  def context_window_size
    model&.context_window || DEFAULT_CONTEXT_WINDOW_SIZE
  end

  # Returns the ratio of estimated active tokens to the model context window.
  # AgentRuntime starts background compaction around 75% usage so the current
  # turn still has roughly 25% headroom while the job prepares a summary.
  #
  # @return [Float]
  def context_window_usage
    window_size = context_window_size
    return 0.0 if window_size.zero?

    estimated_context_tokens.to_f / window_size
  end

  # Archives the session and records when it ended.
  #
  # @return [void]
  def archive!
    update!(status: "archived", ended_at: Time.current)
  end

  # @return [Boolean]
  def archived?
    status == "archived"
  end

  # Returns whether the session has been idle long enough to rotate.
  # Rotation is intentionally invisible to the user: the old session is archived
  # and a fresh one inherits the summary so the agent still has continuity.
  #
  # @return [Boolean]
  def stale?
    return false if last_activity_at.blank?

    last_activity_at < inactivity_threshold.ago
  end

  # Returns the idle window after which a session should rotate.
  # `session_timeout_hours` is stored in agent params because different agents
  # naturally want different conversational boundaries.
  #
  # @return [ActiveSupport::Duration]
  def inactivity_threshold
    hours = normalized_session_timeout_hours
    hours.hours
  end

  # Merges additional metadata into the session context blob.
  #
  # @param updates [Hash]
  # @return [void]
  def merge_context_data!(updates)
    normalized_updates = updates.deep_stringify_keys
    update!(context_data: (context_data || {}).deep_merge(normalized_updates))
  end

  private

  # @param agent [Agent]
  # @param workspace [Workspace]
  # @param gateway [String]
  # @return [Session, nil]
  def self.find_active_session(agent:, workspace:, gateway:)
    active.find_by(agent:, workspace:, gateway:)
  end
  private_class_method :find_active_session

  # @param agent [Agent]
  # @param workspace [Workspace]
  # @param gateway [String]
  # @param inherited_summary [String, nil]
  # @return [Session]
  def self.create_new_session(agent:, workspace:, gateway:, inherited_summary:)
    provider = agent.resolved_provider || AgentRuntime::DEFAULT_PROVIDER

    create_or_find_by!(
      agent:,
      workspace:,
      gateway:,
      status: "active"
    ) do |session|
      timestamp = Time.current
      session.last_activity_at = timestamp
      session.started_at = timestamp
      # Summary inheritance is the lightweight cross-session memory layer.
      session.summary = inherited_summary.presence
      session.model = model_record_for(agent.model_id, provider:)
    end
  end
  private_class_method :create_new_session

  # @param model_id [String]
  # @param provider [String, Symbol]
  # @return [RubyLLM::ModelRecord]
  def self.model_record_for(model_id, provider: AgentRuntime::DEFAULT_PROVIDER.to_s)
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
  private_class_method :model_record_for

  # @return [Hash]
  def normalized_agent_params
    agent.params.is_a?(Hash) ? agent.params.deep_stringify_keys : {}
  end

  # @return [Numeric]
  def normalized_session_timeout_hours
    value = normalized_agent_params["session_timeout_hours"]
    parsed_value = Float(value, exception: false)

    return DEFAULT_SESSION_TIMEOUT_HOURS if parsed_value.blank? || parsed_value <= 0

    parsed_value
  end

  # Prevents sessions from linking agents across workspaces.
  #
  # @return [void]
  def agent_belongs_to_workspace
    return if agent.blank? || workspace.blank?
    return if agent.workspace_id == workspace_id

    errors.add(:agent, "must belong to the current workspace")
  end

  # @return [Boolean]
  def archived_now_with_messages?
    saved_change_to_status? && archived? && messages.where(role: %w[user assistant]).exists?
  end

  # @return [void]
  def enqueue_conversation_archive_job
    ConversationArchiveJob.perform_later(id, workspace_id:)
  end
end

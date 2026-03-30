# frozen_string_literal: true

# Persists one active conversation per workspace, agent, and gateway.
class Session < ApplicationRecord
  include WorkspaceScoped

  acts_as_chat messages: :messages, model_class: "RubyLLM::ModelRecord"

  belongs_to :agent

  validates :gateway, presence: true
  validates :status, presence: true, inclusion: { in: %w[active archived] }
  validate :agent_belongs_to_workspace

  scope :active, -> { where(status: "active") }

  # Finds or creates the active session for the current workspace.
  #
  # @param agent [Agent]
  # @param gateway [String]
  # @return [Session]
  def self.resolve(agent:, gateway: "web")
    workspace = Current.workspace
    raise ArgumentError, "Current.workspace must be set" unless workspace

    session = create_or_find_by!(
      agent:,
      workspace:,
      gateway:,
      status: "active"
    ) do |session|
      session.last_activity_at = Time.current
      session.model = model_record_for(agent.model_id)
    end

    return session if session.model.present?

    session.update!(model: model_record_for(agent.model_id))
    session
  end

  private

  # @param model_id [String]
  # @return [RubyLLM::ModelRecord]
  def self.model_record_for(model_id)
    RubyLLM::ModelRecord.find_or_create_by!(
      model_id:,
      provider: SimpleChatService::PROVIDER.to_s
    ) do |model|
      model.name = model_id
      model.capabilities = []
      model.modalities = {}
      model.pricing = {}
      model.metadata = {}
    end
  end
  private_class_method :model_record_for

  # Prevents sessions from linking agents across workspaces.
  #
  # @return [void]
  def agent_belongs_to_workspace
    return if agent.blank? || workspace.blank?
    return if agent.workspace_id == workspace_id

    errors.add(:agent, "must belong to the current workspace")
  end
end

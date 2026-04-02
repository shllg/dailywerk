# frozen_string_literal: true

# Stores the configuration for a workspace-scoped chat agent.
class Agent < ApplicationRecord
  include WorkspaceScoped

  ALLOWED_PROVIDERS = %w[openai openai_responses anthropic google].freeze
  ALLOWED_MEMORY_ISOLATION = %w[shared isolated read_shared].freeze
  IDENTITY_ALLOWED_KEYS = %w[persona tone constraints].freeze
  THINKING_ALLOWED_KEYS = %w[enabled budget_tokens].freeze
  PARAMS_ALLOWED_KEYS = %w[
    compaction_model
    frequency_penalty
    max_tokens
    presence_penalty
    session_timeout_hours
    stop
    top_p
  ].freeze
  MAX_CONFIG_TEXT_LENGTH = 50_000
  MAX_IDENTITY_VALUE_LENGTH = 20_000
  MAX_PARAMS_JSON_BYTESIZE = 10.kilobytes
  MAX_TOOL_NAMES = 20
  DEFAULT_THINKING_BUDGET_TOKENS = 10_000

  has_many :conversation_archives, dependent: :nullify, inverse_of: :agent
  has_many :memory_entries, dependent: :nullify, inverse_of: :agent
  has_many :sessions, dependent: :destroy, inverse_of: :agent

  validates :slug, presence: true, uniqueness: { scope: :workspace_id }
  validates :name, presence: true
  validates :model_id, presence: true
  validates :soul, length: { maximum: MAX_CONFIG_TEXT_LENGTH }, allow_nil: true
  validates :instructions, length: { maximum: MAX_CONFIG_TEXT_LENGTH }, allow_nil: true
  validates :provider, inclusion: { in: ALLOWED_PROVIDERS }, allow_blank: true
  validates :memory_isolation, inclusion: { in: ALLOWED_MEMORY_ISOLATION }
  validate :validate_identity_schema
  validate :validate_thinking_schema
  validate :validate_params_schema
  validate :validate_tool_names_schema

  scope :active, -> { where(active: true) }

  # @return [String] the system instructions passed to the LLM
  def resolved_instructions
    PromptBuilder.new(self).build
  end

  # @return [Symbol, nil] the configured provider, if present
  def resolved_provider
    provider.presence&.to_sym
  end

  # @return [Hash] the provider thinking config, or an empty hash when disabled
  def thinking_config
    normalized_thinking = thinking_hash
    return {} unless normalized_thinking["enabled"] == true

    {
      thinking: {
        budget_tokens: normalized_thinking.fetch(
          "budget_tokens",
          DEFAULT_THINKING_BUDGET_TOKENS
        )
      }
    }
  end

  # Resolves configured tool names to tool instances for a session.
  #
  # @param user [User, nil]
  # @param session [Session]
  # @return [Array<RubyLLM::Tool>]
  def tool_instances(user:, session:)
    ToolRegistry.build(tool_names, user:, session:)
  end

  private

  # @return [Hash]
  def identity_hash
    identity.is_a?(Hash) ? identity.deep_stringify_keys : {}
  end

  # @return [Hash]
  def thinking_hash
    thinking.is_a?(Hash) ? thinking.deep_stringify_keys : {}
  end

  # @return [Hash]
  def params_hash
    self.params.is_a?(Hash) ? self.params.deep_stringify_keys : {}
  end

  # @return [void]
  def validate_identity_schema
    return if identity.nil? || identity == {}

    unless identity.is_a?(Hash)
      errors.add(:identity, "must be an object")
      return
    end

    unknown_keys = identity_hash.keys - IDENTITY_ALLOWED_KEYS
    if unknown_keys.any?
      errors.add(:identity, "contains unknown keys: #{unknown_keys.join(', ')}")
    end

    identity_hash.each_value do |value|
      unless value.is_a?(String)
        errors.add(:identity, "values must be strings")
        break
      end

      if value.length > MAX_IDENTITY_VALUE_LENGTH
        errors.add(
          :identity,
          "values must be #{MAX_IDENTITY_VALUE_LENGTH} characters or fewer"
        )
        break
      end
    end
  end

  # @return [void]
  def validate_thinking_schema
    return if thinking.nil? || thinking == {}

    unless thinking.is_a?(Hash)
      errors.add(:thinking, "must be an object")
      return
    end

    unknown_keys = thinking_hash.keys - THINKING_ALLOWED_KEYS
    if unknown_keys.any?
      errors.add(:thinking, "contains unknown keys: #{unknown_keys.join(', ')}")
    end

    if thinking_hash.key?("enabled") && ![ true, false ].include?(thinking_hash["enabled"])
      errors.add(:thinking, "enabled must be true or false")
    end

    return unless thinking_hash.key?("budget_tokens")

    budget_tokens = thinking_hash["budget_tokens"]
    unless budget_tokens.is_a?(Integer) && budget_tokens.between?(1, 100_000)
      errors.add(:thinking, "budget_tokens must be an integer between 1 and 100,000")
    end
  end

  # @return [void]
  def validate_params_schema
    return if self.params.nil? || self.params == {}

    unless self.params.is_a?(Hash)
      errors.add(:params, "must be an object")
      return
    end

    unknown_keys = params_hash.keys - PARAMS_ALLOWED_KEYS
    errors.add(:params, "contains unknown keys: #{unknown_keys.join(', ')}") if unknown_keys.any?

    return unless ActiveSupport::JSON.encode(params_hash).bytesize > MAX_PARAMS_JSON_BYTESIZE

    errors.add(:params, "must be 10 KB or smaller")
  end

  # @return [void]
  def validate_tool_names_schema
    return if tool_names.nil?

    unless tool_names.is_a?(Array)
      errors.add(:tool_names, "must be an array")
      return
    end

    if tool_names.length > MAX_TOOL_NAMES
      errors.add(:tool_names, "must contain #{MAX_TOOL_NAMES} entries or fewer")
    end

    unknown = tool_names.reject { |name| ToolRegistry.names.include?(name) }
    errors.add(:tool_names, "contains unknown tools: #{unknown.join(', ')}") if unknown.any?
  end
end

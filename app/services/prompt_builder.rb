# frozen_string_literal: true

# Assembles the system prompt from an agent's stored configuration.
class PromptBuilder
  IDENTITY_SECTIONS = {
    "persona" => "Persona",
    "tone" => "Tone",
    "constraints" => "Constraints"
  }.freeze

  # @param agent [Agent]
  def initialize(agent)
    @agent = agent
  end

  # @return [String] the combined system prompt for the agent
  def build
    sections = []
    sections << @agent.instructions if @agent.instructions.present?
    sections << soul_section if @agent.soul.present?

    assembled_identity = identity_sections
    sections << assembled_identity if assembled_identity.present?

    sections.join("\n\n")
  end

  private

  # @return [String]
  def soul_section
    "## Soul\n\n#{@agent.soul}"
  end

  # @return [String]
  def identity_sections
    normalized_identity = @agent.identity.is_a?(Hash) ? @agent.identity.deep_stringify_keys : {}

    IDENTITY_SECTIONS.filter_map do |key, title|
      value = normalized_identity[key]
      next if value.blank?

      "## #{title}\n\n#{value}"
    end.join("\n\n")
  end
end

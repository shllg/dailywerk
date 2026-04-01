# frozen_string_literal: true

# Updates named sections inside the vault guide markdown.
class VaultGuideUpdater
  SECTION_HEADINGS = {
    "folder_structure" => "## Folder Structure",
    "placement_rules" => "## Placement Rules",
    "naming_conventions" => "## Naming Conventions",
    "frontmatter_schemas" => "## Frontmatter Schemas",
    "linking" => "## Linking",
    "search_relevance" => "## Search Relevance",
    "agent_behaviors" => "## Agent Behaviors"
  }.freeze

  # @param guide_content [String]
  # @param section [String]
  # @param new_section_content [String]
  # @return [String]
  def self.apply_section_update(guide_content, section, new_section_content)
    heading = SECTION_HEADINGS[section]
    raise ArgumentError, "Unknown section: #{section}" unless heading

    parts = guide_content.to_s.split(/(?=^## )/m)
    updated_parts = parts.map do |part|
      next part unless part.start_with?(heading)

      "#{heading}\n\n#{new_section_content.to_s.strip}\n\n"
    end

    unless parts.any? { |part| part.start_with?(heading) }
      updated_parts << "#{heading}\n\n#{new_section_content.to_s.strip}\n"
    end

    updated_parts.join
  end
end

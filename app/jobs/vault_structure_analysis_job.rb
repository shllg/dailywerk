# frozen_string_literal: true

# Analyzes an imported vault structure and writes `_dailywerk` guidance files.
class VaultStructureAnalysisJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param vault_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(vault_id, workspace_id:)
    vault = Vault.find(vault_id)
    file_service = VaultFileService.new(vault:)
    paths = file_service.list

    file_service.write("_dailywerk/vault-analysis.md", build_analysis(paths))
    guide_path = "_dailywerk/vault-guide.md"
    return if File.exist?(file_service.resolve_safe_path(guide_path))

    file_service.write(guide_path, generated_guide(paths))
  end

  private

  # @param paths [Array<String>]
  # @return [String]
  def build_analysis(paths)
    folders = paths.map { |path| File.dirname(path) }.uniq.sort

    <<~MARKDOWN
      # Vault Analysis

      - Total files: #{paths.size}
      - Top-level folders: #{folders.map { |folder| "`#{folder}`" }.join(", ")}

      ## Sample Paths

      #{paths.first(20).map { |path| "- `#{path}`" }.join("\n")}
    MARKDOWN
  end

  # @param paths [Array<String>]
  # @return [String]
  def generated_guide(paths)
    prompt = <<~PROMPT
      You are generating a concise vault guide for a knowledge-management markdown vault.
      Infer a folder structure from these sample paths:

      #{paths.first(100).join("\n")}

      Write markdown with sections:
      - Folder Structure
      - Placement Rules
      - Naming Conventions
      - Frontmatter Schemas
      - Linking
      - Search Relevance
      - Agent Behaviors
    PROMPT

    RubyLLM.chat(model: ENV.fetch("VAULT_STRUCTURE_ANALYSIS_MODEL", "gpt-5.4"))
           .with_temperature(0.3)
           .ask(prompt)
           .content
  rescue StandardError
    Rails.root.join("lib/templates/vault_guide_default.md").read
  end
end

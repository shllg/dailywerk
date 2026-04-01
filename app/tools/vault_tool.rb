# frozen_string_literal: true

# Exposes read/write/search operations for the current workspace vault.
class VaultTool < RubyLLM::Tool
  description "Reads, writes, lists, and searches the current workspace vault"

  param :action, desc: "One of: guide, update_guide, read, write, list, search, backlinks"
  param :path, type: :string, desc: "Relative vault path", required: false
  param :content, type: :string, desc: "Content to write or guide text to apply", required: false
  param :glob, type: :string, desc: "Optional glob for list", required: false
  param :query, type: :string, desc: "Search query", required: false
  param :limit, type: :integer, desc: "Search result limit", required: false
  param :section, type: :string, desc: "Guide section key for partial guide updates", required: false
  param :vault_slug, type: :string, desc: "Optional vault slug when multiple active vaults exist", required: false

  # @param user [User]
  # @param session [Session]
  def initialize(user:, session:)
    @user = user
    @session = session
    @workspace = Current.workspace || session.workspace
  end

  # @param action [String]
  # @param path [String, nil]
  # @param content [String, nil]
  # @param glob [String, nil]
  # @param query [String, nil]
  # @param limit [Integer, nil]
  # @param section [String, nil]
  # @param vault_slug [String, nil]
  # @return [Hash, Array<Hash>]
  def execute(action:, path: nil, content: nil, glob: nil, query: nil, limit: nil, section: nil, vault_slug: nil)
    vault = resolve_vault(vault_slug)
    return { error: "No vault found" } unless vault
    return { error: "Vault is suspended — size limit exceeded" } if vault.status == "suspended" && action == "write"

    case action
    when "guide"
      read_guide(vault)
    when "update_guide"
      update_vault_guide(vault, content:, section:)
    when "read"
      read_file(vault, path)
    when "write"
      write_file(vault, path, content)
    when "list"
      list_files(vault, glob)
    when "search"
      search_files(vault, query, limit)
    when "backlinks"
      backlinks_for(vault, path)
    else
      { error: "unsupported vault action" }
    end
  rescue VaultFileService::PathTraversalError => e
    { error: "Invalid path: #{e.message}" }
  rescue ActiveRecord::RecordNotFound
    { error: "File not found: #{path}" }
  rescue ArgumentError => e
    { error: e.message }
  end

  private

  # @param vault_slug [String, nil]
  # @return [Vault, nil]
  def resolve_vault(vault_slug)
    return unless @workspace

    scope = @workspace.vaults.active
    return scope.find_by(slug: vault_slug) if vault_slug.present?

    scope.first
  end

  # @param vault [Vault]
  # @return [Hash]
  def read_guide(vault)
    {
      guide: VaultFileService.new(vault: vault).read("_dailywerk/vault-guide.md")
    }
  end

  # @param vault [Vault]
  # @param path [String, nil]
  # @return [Hash]
  def read_file(vault, path)
    raise ArgumentError, "path is required" if path.blank?

    file_service = VaultFileService.new(vault: vault)
    vault_file = vault.vault_files.find_by(path: path)

    {
      path: path,
      content: file_service.read(path),
      backlinks: Array(vault_file&.incoming_links&.includes(:source)).map { |link| link.source.path },
      tags: vault_file&.tags || [],
      frontmatter: vault_file&.frontmatter || {}
    }
  end

  # @param vault [Vault]
  # @param path [String, nil]
  # @param content [String, nil]
  # @return [Hash]
  def write_file(vault, path, content)
    raise ArgumentError, "path is required" if path.blank?
    raise ArgumentError, "content is required" if content.nil?
    raise ArgumentError, "writes to _dailywerk are restricted" if managed_path?(path)
    raise ArgumentError, "file type is not agent writable" unless VaultFile.agent_writable?(path)

    VaultFileService.new(vault: vault).write(path, content.to_s)
    VaultFileChangedJob.perform_later(vault.id, path, "modify", workspace_id: vault.workspace_id)

    {
      path: path,
      status: "written",
      note: "Indexing and S3 sync will happen automatically."
    }
  end

  # @param vault [Vault]
  # @param glob [String, nil]
  # @return [Array<Hash>]
  def list_files(vault, glob)
    VaultFileService.new(vault: vault).list(glob: glob.presence || "**/*").map do |path|
      {
        path: path
      }
    end
  end

  # @param vault [Vault]
  # @param query [String, nil]
  # @param limit [Integer, nil]
  # @return [Array<Hash>]
  def search_files(vault, query, limit)
    results = VaultSearchService.new(vault: vault).search(query.to_s, limit: limit.presence || 5)

    results.map do |chunk|
      {
        path: chunk.file_path,
        heading_path: chunk.heading_path,
        snippet: chunk.content.tr("\n", " ")[0, 280]
      }
    end
  end

  # @param vault [Vault]
  # @param path [String, nil]
  # @return [Array<Hash>]
  def backlinks_for(vault, path)
    raise ArgumentError, "path is required" if path.blank?

    vault_file = vault.vault_files.find_by!(path: path)
    vault_file.incoming_links.includes(:source).map do |link|
      {
        path: link.source.path,
        link_type: link.link_type,
        link_text: link.link_text,
        context: link.context
      }
    end
  end

  # @param vault [Vault]
  # @param content [String, nil]
  # @param section [String, nil]
  # @return [Hash]
  def update_vault_guide(vault, content:, section:)
    raise ArgumentError, "content is required" if content.nil?

    file_service = VaultFileService.new(vault: vault)
    current_guide = file_service.read("_dailywerk/vault-guide.md")
    updated_guide = if section.present?
      VaultGuideUpdater.apply_section_update(current_guide, section, content)
    else
      content.to_s
    end

    file_service.write("_dailywerk/vault-guide.md", updated_guide)
    VaultFileChangedJob.perform_later(
      vault.id,
      "_dailywerk/vault-guide.md",
      "modify",
      workspace_id: vault.workspace_id
    )

    {
      status: "updated",
      section: section,
      note: "Vault guide updated. Changes take effect on the next interaction."
    }
  end

  # @param path [String]
  # @return [Boolean]
  def managed_path?(path)
    path.to_s.start_with?("_dailywerk/")
  end
end

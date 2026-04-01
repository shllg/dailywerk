# frozen_string_literal: true

require "digest"

# Re-indexes one file after a local vault change is detected.
class VaultFileChangedJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "vault_file_changed:#{arguments[0]}:#{arguments[1]}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param vault_id [String]
  # @param relative_path [String]
  # @param event_type [String]
  # @param workspace_id [String]
  # @param old_path [String, nil]
  # @return [void]
  def perform(vault_id, relative_path, event_type, workspace_id:, old_path: nil)
    vault = Vault.find(vault_id)

    case event_type.to_s
    when "delete", "deleted"
      delete_file(vault, relative_path)
    when "move", "moved"
      move_file(vault, old_path: old_path, new_path: relative_path)
    else
      process_file(vault, relative_path)
    end
  end

  private

  # @param vault [Vault]
  # @param relative_path [String]
  # @return [void]
  def process_file(vault, relative_path)
    file_service = VaultFileService.new(vault: vault)
    absolute_path = file_service.resolve_safe_path(relative_path)
    raw_content = file_service.read(relative_path)
    content_hash = Digest::SHA256.file(absolute_path).hexdigest
    stat = File.stat(absolute_path)
    file_type = VaultFile.file_type_for(relative_path)
    record = vault.vault_files.find_or_initialize_by(path: relative_path)

    return if record.persisted? && record.content_hash == content_hash && record.last_modified == stat.mtime

    frontmatter, text_content, tags, title = markdown_metadata_for(
      file_type: file_type,
      raw_content: raw_content,
      relative_path: relative_path
    )

    record.assign_attributes(
      workspace: vault.workspace,
      file_type: file_type,
      content_type: VaultFile.content_type_for(relative_path),
      content_hash: content_hash,
      size_bytes: stat.size,
      frontmatter: frontmatter,
      tags: tags,
      title: title,
      last_modified: stat.mtime
    )
    record.save!

    if record.markdown?
      rechunk(record, text_content)
      relink(record, text_content)
      record.update!(indexed_at: Time.current)
    else
      record.vault_chunks.delete_all
      record.outgoing_links.delete_all
      record.update!(indexed_at: nil)
    end
  end

  # @param vault [Vault]
  # @param relative_path [String]
  # @return [void]
  def delete_file(vault, relative_path)
    vault.vault_files.find_by(path: relative_path)&.destroy!
  end

  # @param vault [Vault]
  # @param old_path [String, nil]
  # @param new_path [String]
  # @return [void]
  def move_file(vault, old_path:, new_path:)
    raise ArgumentError, "old_path is required for moved files" if old_path.blank?

    record = vault.vault_files.find_by(path: old_path)
    return process_file(vault, new_path) unless record

    record.update!(path: new_path)
    record.vault_chunks.update_all(file_path: new_path)
    process_file(vault, new_path)
    VaultLinkRepairJob.perform_later(vault.id, old_path, new_path, workspace_id: vault.workspace_id)
  end

  # @param record [VaultFile]
  # @param content [String]
  # @return [void]
  def rechunk(record, content)
    chunks = MarkdownChunker.new(content, file_path: record.path).call

    VaultChunk.transaction do
      record.vault_chunks.delete_all

      chunks.each do |chunk|
        vault_chunk = record.vault_chunks.create!(chunk.merge(workspace: record.workspace))
        GenerateEmbeddingJob.perform_later("VaultChunk", vault_chunk.id, workspace_id: record.workspace_id)
      end
    end
  end

  # @param record [VaultFile]
  # @param content [String]
  # @return [void]
  def relink(record, content)
    extractor = VaultLinkExtractor.new(vault: record.vault, source_path: record.path)

    VaultLink.transaction do
      record.outgoing_links.delete_all

      extractor.call(content).each do |link|
        target = record.vault.vault_files.find_by(path: link[:resolved_target])
        next unless target

        record.outgoing_links.create!(
          workspace: record.workspace,
          target: target,
          link_type: link[:link_type],
          link_text: link[:link_text],
          context: link[:context]
        )
      end
    end
  end

  # @param file_type [String]
  # @param raw_content [String]
  # @param relative_path [String]
  # @return [Array<(Hash, String, Array<String>, String)>]
  def markdown_metadata_for(file_type:, raw_content:, relative_path:)
    return [ {}, "", [], nil ] unless file_type == "markdown"

    content = raw_content
      .dup
      .force_encoding(Encoding::UTF_8)
      .encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    frontmatter, body = MarkdownChunker.extract_frontmatter(content)
    extractor = VaultLinkExtractor.new(vault: nil, source_path: relative_path)
    tags = (frontmatter_tags(frontmatter) + extractor.tags(content)).uniq.sort
    title = MarkdownChunker.extract_title(content, frontmatter: frontmatter, path: relative_path)

    [ frontmatter, body, tags, title ]
  end

  # @param frontmatter [Hash]
  # @return [Array<String>]
  def frontmatter_tags(frontmatter)
    value = frontmatter["tags"]

    case value
    when Array
      value.map(&:to_s)
    when String
      value.split(",").map(&:strip)
    else
      []
    end
  end
end

# frozen_string_literal: true

require "fileutils"
require "tempfile"

# Provides safe local filesystem access for one vault checkout.
class VaultFileService
  class PathTraversalError < SecurityError; end

  # @param vault [Vault]
  def initialize(vault:)
    @vault = vault
    FileUtils.mkdir_p(@vault.local_path)
    @base = File.realpath(@vault.local_path)
    @base_prefix = "#{@base}#{File::SEPARATOR}"
  end

  # Reads a file from the vault.
  #
  # @param path [String]
  # @return [String]
  def read(path)
    absolute_path = resolve_safe_path(path)
    raise ActiveRecord::RecordNotFound, "File not found: #{path}" unless File.exist?(absolute_path)

    File.binread(absolute_path)
  end

  # Writes content atomically inside the vault.
  #
  # @param path [String]
  # @param content [String]
  # @return [void]
  def write(path, content)
    raise PathTraversalError, "vault is suspended" if @vault.over_limit?

    absolute_path = resolve_safe_path(path)
    FileUtils.mkdir_p(File.dirname(absolute_path))

    tempfile = Tempfile.new([ File.basename(path), ".tmp" ], File.dirname(absolute_path))
    tempfile.binmode
    tempfile.write(content)
    tempfile.flush
    tempfile.fsync
    tempfile.close
    File.rename(tempfile.path, absolute_path)
  ensure
    tempfile&.close!
  end

  # Lists relative file paths under the vault base.
  #
  # @param glob [String]
  # @return [Array<String>]
  def list(glob: "**/*")
    Dir.glob(File.join(@base, glob), File::FNM_DOTMATCH).sort.filter_map do |absolute_path|
      next if File.directory?(absolute_path)

      relative_path = relative_path_for(absolute_path)
      next if ignored_path?(relative_path)

      relative_path
    end
  end

  # Deletes a file from the vault if it exists.
  #
  # @param path [String]
  # @return [void]
  def delete(path)
    absolute_path = resolve_safe_path(path)
    File.delete(absolute_path) if File.exist?(absolute_path)
  end

  # Resolves a user-supplied relative path and rejects traversal or symlink escapes.
  #
  # @param path [String]
  # @return [String]
  def resolve_safe_path(path)
    relative_path = normalize_relative_path(path)
    absolute_path = File.expand_path(relative_path, @base)

    ensure_within_base!(absolute_path)
    ensure_realpath_within_base!(absolute_path)
    absolute_path
  end

  # @param path [String]
  # @return [Boolean] whether the path should be ignored by vault indexing
  def ignored_path?(path)
    parts = path.to_s.split(File::SEPARATOR)
    return true if parts.empty?

    path.to_s.start_with?(".obsidian/") ||
      path.to_s.start_with?(".trash/") ||
      parts.any? { |part| part.start_with?(".") }
  end

  private

  # @param path [String]
  # @return [String]
  def normalize_relative_path(path)
    value = path.to_s.tr("\\", "/").sub(%r{\A/+}, "")

    raise PathTraversalError, "path must not be blank" if value.blank?
    raise PathTraversalError, "path contains null bytes" if value.include?("\0")
    raise PathTraversalError, "dot segments are not allowed" if value.split("/").any? { |part| part == ".." }

    value
  end

  # @param absolute_path [String]
  # @return [void]
  def ensure_within_base!(absolute_path)
    return if absolute_path == @base || absolute_path.start_with?(@base_prefix)

    raise PathTraversalError, "path escapes the vault base"
  end

  # @param absolute_path [String]
  # @return [void]
  def ensure_realpath_within_base!(absolute_path)
    existing_path = absolute_path

    until File.exist?(existing_path) || existing_path == @base
      parent_path = File.dirname(existing_path)
      break if parent_path == existing_path

      existing_path = parent_path
    end

    real_existing_path = File.realpath(existing_path)
    return if real_existing_path == @base || real_existing_path.start_with?(@base_prefix)

    raise PathTraversalError, "path escapes the vault base via symlink"
  end

  # @param absolute_path [String]
  # @return [String]
  def relative_path_for(absolute_path)
    return "" if absolute_path == @base

    absolute_path.start_with?(@base_prefix) ? absolute_path[@base_prefix.length..] : absolute_path
  end
end

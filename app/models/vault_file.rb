# frozen_string_literal: true

require "marcel"

# Stores metadata for one file inside a workspace vault.
class VaultFile < ApplicationRecord
  include WorkspaceScoped

  MARKDOWN_EXTENSIONS = %w[.md].freeze
  CANVAS_EXTENSIONS = %w[.canvas].freeze
  IMAGE_EXTENSIONS = %w[.avif .bmp .gif .jpeg .jpg .png .svg .webp].freeze
  PDF_EXTENSIONS = %w[.pdf].freeze
  AUDIO_EXTENSIONS = %w[.flac .m4a .mp3 .ogg .wav .webm .3gp].freeze
  VIDEO_EXTENSIONS = %w[.mkv .mov .mp4 .ogv .webm].freeze
  FILE_TYPES = %w[markdown canvas image pdf audio video other].freeze
  AGENT_WRITABLE_TYPES = %w[markdown image pdf].freeze

  belongs_to :vault, inverse_of: :vault_files
  has_many :vault_chunks, dependent: :delete_all, inverse_of: :vault_file
  has_many :outgoing_links,
           class_name: "VaultLink",
           foreign_key: :source_id,
           dependent: :delete_all,
           inverse_of: :source
  has_many :incoming_links,
           class_name: "VaultLink",
           foreign_key: :target_id,
           dependent: :delete_all,
           inverse_of: :target

  validates :path, presence: true, uniqueness: { scope: :vault_id }
  validates :file_type, inclusion: { in: FILE_TYPES }
  validate :vault_matches_workspace

  scope :markdown, -> { where(file_type: "markdown") }

  # @return [Boolean] whether the file is a markdown note
  def markdown?
    file_type == "markdown"
  end

  # @return [Boolean] whether the agent may modify this file type
  def agent_writable?
    self.class.agent_writable_type?(file_type)
  end

  # @param file_type [String]
  # @return [Boolean]
  def self.agent_writable_type?(file_type)
    AGENT_WRITABLE_TYPES.include?(file_type)
  end

  # @param path [String]
  # @return [String] the normalized file type derived from the path
  def self.file_type_for(path)
    extension = File.extname(path.to_s).downcase

    return "markdown" if MARKDOWN_EXTENSIONS.include?(extension)
    return "canvas" if CANVAS_EXTENSIONS.include?(extension)
    return "image" if IMAGE_EXTENSIONS.include?(extension)
    return "pdf" if PDF_EXTENSIONS.include?(extension)
    return "audio" if AUDIO_EXTENSIONS.include?(extension)
    return "video" if VIDEO_EXTENSIONS.include?(extension)

    "other"
  end

  # @param path [String]
  # @return [String] the normalized file type derived from the path
  def self.detect_file_type(path)
    file_type_for(path)
  end

  # @param path [String]
  # @return [Boolean] whether the agent may create or replace the path
  def self.agent_writable?(path)
    agent_writable_type?(file_type_for(path))
  end

  # @param path [String]
  # @return [String] the MIME type for the given file path
  def self.content_type_for(path)
    case file_type_for(path)
    when "markdown"
      "text/markdown"
    when "canvas"
      "application/json"
    else
      Marcel::MimeType.for(name: path).presence || "application/octet-stream"
    end
  end

  private

  # @return [void]
  def vault_matches_workspace
    return if vault.blank? || workspace.blank?
    return if vault.workspace_id == workspace_id

    errors.add(:vault, "must belong to the current workspace")
  end
end

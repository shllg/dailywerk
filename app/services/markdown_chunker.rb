# frozen_string_literal: true

require "date"
require "yaml"

# Splits Obsidian-style markdown into search-sized sections.
class MarkdownChunker
  CHUNK_TARGET_SIZE = 6_000
  MIN_CHUNK_LENGTH = 100
  HEADING_REGEX = /\A(#{'#' * 3}|#{'#' * 2}|#)\s+(.+?)\s*\z/

  # @param content [String]
  # @param file_path [String]
  def initialize(content, file_path:)
    @content = content.to_s
    @file_path = file_path
  end

  # @return [Array<Hash>] normalized chunk payloads ready for persistence
  def call
    frontmatter, body = self.class.extract_frontmatter(@content)
    sections = build_sections(body)
    chunks = []
    chunk_idx = 0

    sections.each do |section|
      split_section_content(section[:content]).each do |chunk_content|
        next if chunk_content.length < MIN_CHUNK_LENGTH

        chunks << {
          chunk_idx:,
          content: chunk_content,
          file_path: @file_path,
          heading_path: section[:heading_path],
          metadata: {
            frontmatter: frontmatter
          }
        }
        chunk_idx += 1
      end
    end

    chunks
  end

  # Extracts and parses YAML frontmatter safely.
  #
  # @param content [String]
  # @return [Array<(Hash, String)>]
  def self.extract_frontmatter(content)
    return [ {}, content.to_s ] unless content.to_s.start_with?("---\n")

    match = content.match(/\A---\s*\n(.*?)\n---\s*\n?/m)
    return [ {}, content.to_s ] unless match

    frontmatter = YAML.safe_load(
      match[1],
      permitted_classes: [ Date, Time ],
      aliases: false
    )
    normalized = frontmatter.is_a?(Hash) ? frontmatter.deep_stringify_keys : {}

    [ normalized, content[match[0].length..].to_s ]
  rescue Psych::Exception
    [ {}, content.to_s ]
  end

  # @param content [String]
  # @param frontmatter [Hash]
  # @param path [String]
  # @return [String]
  def self.extract_title(content, frontmatter:, path:)
    return frontmatter["title"].to_s if frontmatter["title"].present?

    heading_match = content.to_s.match(/^#\s+(.+?)\s*$/)
    return heading_match[1].strip if heading_match

    File.basename(path.to_s, File.extname(path.to_s)).tr("-_", " ").strip.presence || "Untitled"
  end

  private

  # @param body [String]
  # @return [Array<Hash>]
  def build_sections(body)
    sections = []
    current_heading = []
    current_lines = []

    body.to_s.each_line do |line|
      heading_match = line.match(HEADING_REGEX)

      if heading_match
        sections << build_section(current_heading, current_lines) if current_lines.any?
        level = heading_match[1].length
        current_heading = current_heading.first(level - 1)
        current_heading[level - 1] = heading_match[2].strip
        current_lines = [ line ]
      else
        current_lines << line
      end
    end

    sections << build_section(current_heading, current_lines) if current_lines.any?
    sections.presence || [ build_section([], [ body.to_s ]) ]
  end

  # @param heading_parts [Array<String>]
  # @param lines [Array<String>]
  # @return [Hash]
  def build_section(heading_parts, lines)
    {
      heading_path: heading_parts.compact.join(" > ").presence,
      content: lines.join.strip
    }
  end

  # @param content [String]
  # @return [Array<String>]
  def split_section_content(content)
    return [ content.strip ] if content.length <= CHUNK_TARGET_SIZE

    paragraphs = content.split(/\n{2,}/)
    chunks = []
    buffer = +""

    paragraphs.each do |paragraph|
      paragraph = paragraph.strip
      next if paragraph.blank?

      proposed = buffer.blank? ? paragraph : "#{buffer}\n\n#{paragraph}"
      if proposed.length > CHUNK_TARGET_SIZE && buffer.present?
        chunks << buffer
        buffer = paragraph
      else
        buffer = proposed
      end
    end

    chunks << buffer if buffer.present?
    chunks
  end
end

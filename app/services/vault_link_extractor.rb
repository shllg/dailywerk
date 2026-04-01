# frozen_string_literal: true

require "pathname"

# Extracts wikilinks, embeds, and inline tags from Obsidian markdown.
class VaultLinkExtractor
  WIKILINK_REGEX = /(?<embed>!)?\[\[(?<body>(?:\\.|[^\]])+)\]\]/
  TAG_REGEX = /(?<![\w`])#(?<tag>[[:alnum:]_\/-]+)/

  # @param vault [Vault, nil]
  # @param source_path [String, nil]
  def initialize(vault:, source_path: nil)
    @vault = vault
    @source_path = source_path
  end

  # @param content [String]
  # @return [Array<Hash>]
  def call(content)
    sanitized = strip_comments(content.to_s)
    links = []

    sanitized.to_enum(:scan, WIKILINK_REGEX).each do
      embed_flag, body = Regexp.last_match.values_at(:embed, :body)
      target_text, alias_text = split_link_body(body)
      resolved_target = resolve_target(target_text)
      next if resolved_target.blank?

      links << {
        link_type: embed_flag.present? ? "embed" : "wikilink",
        link_text: alias_text.presence || target_text,
        resolved_target: resolved_target,
        target_path: resolved_target,
        context: Regexp.last_match[0]
      }
    end

    links
  end

  # @param content [String]
  # @return [Array<String>]
  def tags(content)
    strip_comments(content.to_s)
      .scan(TAG_REGEX)
      .flatten
      .map(&:strip)
      .reject(&:blank?)
      .uniq
      .sort
  end

  private

  # @param content [String]
  # @return [String]
  def strip_comments(content)
    content.gsub(/%%.*?%%/m, "")
  end

  # @param body [String]
  # @return [Array<(String, String)>]
  def split_link_body(body)
    separator = body.match(/\\\||(?<!\\)\|/)
    return [ unescape(body), "" ] unless separator

    [
      unescape(body[0...separator.begin(0)]),
      unescape(body[separator.end(0)..].to_s)
    ]
  end

  # @param text [String]
  # @return [String]
  def unescape(text)
    text.to_s.gsub("\\|", "|").gsub("\\\\", "\\").strip
  end

  # @param raw_target [String]
  # @return [String, nil]
  def resolve_target(raw_target)
    base = raw_target.to_s.gsub("\\|", "|").split("#").first.to_s.strip
    return if base.blank?

    base += ".md" unless File.extname(base).present?
    base = File.join(File.dirname(@source_path), base) if @source_path.present? && !base.include?("/")
    base = Pathname.new(base).cleanpath.to_s.sub(%r{\A\./}, "")
    return if base.start_with?("../")

    base
  end
end

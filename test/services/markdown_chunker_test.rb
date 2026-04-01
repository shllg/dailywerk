# frozen_string_literal: true

require "test_helper"

class MarkdownChunkerTest < ActiveSupport::TestCase
  # rubocop:disable Minitest/MultipleAssertions
  test "splits markdown by heading and preserves frontmatter metadata" do
    content = <<~MARKDOWN
      ---
      tags:
        - planning
      ---

      # Planning

      #{'A' * 140}

      ## Tasks

      #{'B' * 140}
    MARKDOWN

    chunks = MarkdownChunker.new(content, file_path: "notes/planning.md").call
    frontmatter = chunks.first[:metadata][:frontmatter]

    assert_equal 2, chunks.size
    assert_equal "Planning", chunks.first[:heading_path]
    assert_equal "Planning > Tasks", chunks.last[:heading_path]
    assert_equal "planning", Array(frontmatter["tags"]).first
  end
  # rubocop:enable Minitest/MultipleAssertions
end

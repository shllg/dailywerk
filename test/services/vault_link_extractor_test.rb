# frozen_string_literal: true

require "test_helper"

class VaultLinkExtractorTest < ActiveSupport::TestCase
  test "extracts references, embeds, and tags while skipping comments" do
    extractor = VaultLinkExtractor.new(vault: nil)
    content = <<~MARKDOWN
      [[note-one|Alias]]
      ![[image.png]]
      #topic
      %% [[ignored]] %%
      [[release.v1]]
    MARKDOWN

    links = extractor.call(content)

    assert_equal [ "note-one.md", "image.png", "release.v1" ], links.map { |link| link[:resolved_target] }
    assert_equal [ "wikilink", "embed", "wikilink" ], links.map { |link| link[:link_type] }
    assert_equal [ "topic" ], extractor.tags(content)
  end
end

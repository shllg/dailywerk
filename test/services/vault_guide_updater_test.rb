# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultGuideUpdaterTest < ActiveSupport::TestCase
  test "replaces an existing guide section" do
    content = <<~MARKDOWN
      # Vault Guide

      ## Folder Structure

      Old rules

      ## Linking

      Existing links
    MARKDOWN

    updated = VaultGuideUpdater.apply_section_update(
      content,
      "folder_structure",
      "- Use inbox/ for temporary captures"
    )

    assert_includes updated, "## Folder Structure"
    assert_includes updated, "- Use inbox/ for temporary captures"
    assert_includes updated, "## Linking"
  end

  test "appends a missing guide section" do
    updated = VaultGuideUpdater.apply_section_update(
      "# Vault Guide\n",
      "agent_behaviors",
      "- Prefer concise summaries"
    )

    assert_includes updated, "## Agent Behaviors"
    assert_includes updated, "- Prefer concise summaries"
  end
end
# rubocop:enable Minitest/MultipleAssertions

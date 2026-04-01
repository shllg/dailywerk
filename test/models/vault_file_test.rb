# frozen_string_literal: true

require "test_helper"

class VaultFileTest < ActiveSupport::TestCase
  # rubocop:disable Minitest/MultipleAssertions
  test "detects file types and agent writable paths" do
    assert_equal "markdown", VaultFile.detect_file_type("notes/today.md")
    assert_equal "image", VaultFile.detect_file_type("assets/photo.png")
    assert_equal "pdf", VaultFile.detect_file_type("docs/report.pdf")
    assert_equal "other", VaultFile.detect_file_type("blob.bin")

    assert VaultFile.agent_writable?("notes/today.md")
    assert VaultFile.agent_writable?("assets/photo.png")
    assert VaultFile.agent_writable?("docs/report.pdf")
    assert_not VaultFile.agent_writable?("audio/call.mp3")
  end
  # rubocop:enable Minitest/MultipleAssertions
end

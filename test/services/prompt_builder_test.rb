# frozen_string_literal: true

require "test_helper"

class PromptBuilderTest < ActiveSupport::TestCase
  test "returns an empty string when the agent has no prompt fields" do
    agent = Agent.new(instructions: nil, soul: nil, identity: nil)

    assert_equal "", PromptBuilder.new(agent).build
  end

  test "returns the base instructions when only instructions are set" do
    agent = Agent.new(instructions: "Be concise.")

    assert_equal "Be concise.", PromptBuilder.new(agent).build
  end

  test "assembles instructions, soul, and identity sections" do
    agent = Agent.new(
      instructions: "Answer directly.",
      soul: "Warm but rigorous.",
      identity: {
        persona: "Operations chief",
        tone: "Calm",
        constraints: "No fluff"
      }
    )

    assert_equal(
      [
        "Answer directly.",
        "## Soul\n\nWarm but rigorous.",
        "## Persona\n\nOperations chief",
        "## Tone\n\nCalm",
        "## Constraints\n\nNo fluff"
      ].join("\n\n"),
      PromptBuilder.new(agent).build
    )
  end

  test "skips empty identity fields" do
    agent = Agent.new(
      instructions: "Answer directly.",
      identity: {
        persona: "",
        tone: "Calm"
      }
    )

    assert_equal(
      [
        "Answer directly.",
        "## Tone\n\nCalm"
      ].join("\n\n"),
      PromptBuilder.new(agent).build
    )
  end
end

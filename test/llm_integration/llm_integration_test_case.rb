# frozen_string_literal: true

require "test_helper"

# Base class for live provider checks that should never run in the default suite.
class LlmIntegrationTestCase < ActiveSupport::TestCase
  parallelize_me!

  setup do
    require_live_llm_tests!
  end

  private

  def require_live_llm_tests!
    return if ENV["RUN_LIVE_LLM_TESTS"] == "1"

    skip "Set RUN_LIVE_LLM_TESTS=1 to run live LLM integration tests"
  end

  def require_openai_api_key!
    return if ENV["OPENAI_API_KEY"].present?

    skip "Set OPENAI_API_KEY to run live OpenAI integration tests"
  end
end

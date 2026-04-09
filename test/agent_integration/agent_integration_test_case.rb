# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# Base class for live agent integration tests that should never run by default.
class AgentIntegrationTestCase < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    require_agent_integration_tests!
    require_openai_api_key!

    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @original_vault_local_base = Rails.configuration.x.vault_local_base
    @temp_local_base = Dir.mktmpdir("agent-integration-vaults")
    Rails.configuration.x.vault_local_base = @temp_local_base
  end

  teardown do
    Rails.configuration.x.vault_local_base = @original_vault_local_base if @original_vault_local_base
    FileUtils.rm_rf(@temp_local_base) if @temp_local_base
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter if @original_queue_adapter
  end

  private

  def require_agent_integration_tests!
    return if ENV["RUN_AGENT_INTEGRATION_TESTS"] == "1"

    skip "Set RUN_AGENT_INTEGRATION_TESTS=1 to run live agent integration tests"
  end

  def require_openai_api_key!
    return if ENV["OPENAI_API_KEY"].present?

    skip "Set OPENAI_API_KEY to run live agent integration tests"
  end
end

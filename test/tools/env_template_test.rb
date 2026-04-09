# frozen_string_literal: true

require "test_helper"

class EnvTemplateTest < ActiveSupport::TestCase
  TEMPLATE_PATH = Rails.root.join(".env.tpl")
  SCAN_PATTERNS = %w[
    app/**/*.rb
    config/**/*.rb
    config/**/*.yml
    lib/**/*.rb
    deploy/**/*.ts
    deploy/**/*.js
    frontend/**/*.ts
    frontend/**/*.tsx
    frontend/**/*.js
    frontend/**/*.jsx
  ].freeze
  REQUIRED_EXTRAS = %w[
    RAILS_MASTER_KEY
    SECRET_KEY_BASE
    WORKOS_API_KEY
    WORKOS_CLIENT_ID
    STRIPE_SECRET_KEY
    STRIPE_WEBHOOK_SECRET
    STRIPE_PUBLISHABLE_KEY
    PORT
    SKIP_DOCKER
    RUN_LIVE_LLM_TESTS
    RUN_AGENT_INTEGRATION_TESTS
    PARALLEL_WORKERS
    PARALLELIZE_THRESHOLD
  ].freeze
  IGNORED_REFERENCES = %w[
    BUNDLE_GEMFILE
    CI
  ].freeze

  test ".env.tpl documents the full runtime contract" do
    missing_keys = documented_env_keys_needed_by_runtime - template_keys

    assert_empty(
      missing_keys,
      ".env.tpl is missing environment variables: #{missing_keys.join(', ')}"
    )
  end

  private

  def documented_env_keys_needed_by_runtime
    (referenced_env_keys + REQUIRED_EXTRAS - IGNORED_REFERENCES).uniq.sort
  end

  def referenced_env_keys
    source_paths.flat_map do |path|
      extract_env_keys(File.read(path))
    end.uniq
  end

  def source_paths
    SCAN_PATTERNS.flat_map do |pattern|
      Dir.glob(Rails.root.join(pattern).to_s)
    end.sort.uniq
  end

  def extract_env_keys(content)
    ruby_keys = content.scan(/ENV(?:\.fetch\(|\[)(["'])([A-Z][A-Z0-9_]+)\1/).map(&:last)
    javascript_keys = content.scan(/process\.env\.([A-Z][A-Z0-9_]+)/).flatten

    (ruby_keys + javascript_keys).uniq
  end

  def template_keys
    @template_keys ||= File.readlines(TEMPLATE_PATH).filter_map do |line|
      line[/^\s*#?\s*([A-Z][A-Z0-9_]*)=/, 1]
    end.uniq.sort
  end
end

# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../lib/env_loader"

class EnvLoaderTest < ActiveSupport::TestCase
  test "loads .env before .env.worktree" do
    with_temp_env_files(
      ".env" => "PORT=3000\nVALKEY_URL=redis://localhost:6399/0\n",
      ".env.worktree" => "PORT=4100\n"
    ) do |root|
      env = {}

      EnvLoader.load!(root:, env:)

      assert_equal "4100", env["PORT"]
      assert_equal "redis://localhost:6399/0", env["VALKEY_URL"]
    end
  end

  test "does not overwrite explicit process env" do
    with_temp_env_files(
      ".env" => "PORT=3000\n",
      ".env.worktree" => "PORT=4100\nVALKEY_URL=redis://localhost:6399/0\n"
    ) do |root|
      env = { "PORT" => "5200" }

      EnvLoader.load!(root:, env:)

      assert_equal "5200", env["PORT"]
      assert_equal "redis://localhost:6399/0", env["VALKEY_URL"]
    end
  end

  test "shell exports match load precedence" do
    with_temp_env_files(
      ".env" => "PORT=3000\n",
      ".env.worktree" => "PORT=4100\nGOOD_JOB_ENABLE_CRON=false\n"
    ) do |root|
      exports = EnvLoader.shell_exports(root:, env: {})

      assert_includes exports, "export PORT=4100"
      assert_includes exports, "export GOOD_JOB_ENABLE_CRON=false"
    end
  end

  test "ignores blank placeholder values" do
    with_temp_env_files(
      ".env" => "SECRET_KEY_BASE=\nMETRICS_BASIC_AUTH_USERNAME=\nOPENAI_API_KEY=test-key\n"
    ) do |root|
      env = {}

      EnvLoader.load!(root:, env:)

      refute env.key?("SECRET_KEY_BASE")
      refute env.key?("METRICS_BASIC_AUTH_USERNAME")
      assert_equal "test-key", env["OPENAI_API_KEY"]
    end
  end

  private

  def with_temp_env_files(files)
    Dir.mktmpdir do |root|
      files.each do |filename, content|
        File.write(File.join(root, filename), content)
      end

      yield root
    end
  end
end

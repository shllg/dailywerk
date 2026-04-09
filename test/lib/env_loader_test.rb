# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../lib/env_loader"

class EnvLoaderTest < ActiveSupport::TestCase
  test "loads .env before .env.local before .env.worktree" do
    with_temp_env_files(
      ".env" => "PORT=3000\nVALKEY_URL=redis://localhost:6399/0\n",
      ".env.local" => "PORT=3200\n",
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
      ".env.local" => "PORT=3200\n",
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
      ".env.local" => "PORT=3200\n",
      ".env.worktree" => "PORT=4100\nGOOD_JOB_ENABLE_CRON=false\n"
    ) do |root|
      exports = EnvLoader.shell_exports(root:, env: {})

      assert_includes exports, "export PORT=4100"
      assert_includes exports, "export GOOD_JOB_ENABLE_CRON=false"
    end
  end

  test "shell exports override inherited env values with current repo config" do
    with_temp_env_files(
      ".env.tpl" => "# VAULT_LOCAL_BASE=\n",
      ".env" => "VAULT_LOCAL_BASE=/shared/workspaces\n",
      ".env.local" => "VAULT_LOCAL_BASE=/user/workspaces\n",
      ".env.worktree" => "VAULT_LOCAL_BASE=/worktree/tmp/workspaces\n"
    ) do |root|
      exports = EnvLoader.shell_exports(root:, env: { "VAULT_LOCAL_BASE" => "/stale/workspaces" })

      assert_includes exports, "export VAULT_LOCAL_BASE=/worktree/tmp/workspaces"
    end
  end

  test "shell exports unset stale template keys removed from repo env files" do
    with_temp_env_files(
      ".env.tpl" => "# VAULT_LOCAL_BASE=\n",
      ".env" => "PORT=3000\n"
    ) do |root|
      exports = EnvLoader.shell_exports(root:, env: { "VAULT_LOCAL_BASE" => "/stale/workspaces" })

      assert_includes exports, "unset VAULT_LOCAL_BASE"
    end
  end

  test "ignores blank placeholder values" do
    with_temp_env_files(
      ".env" => "SECRET_KEY_BASE=\nMETRICS_BASIC_AUTH_USERNAME=\nOPENAI_API_KEY=test-key\n",
      ".env.local" => "OPENAI_API_KEY=override-key\n"
    ) do |root|
      env = {}

      EnvLoader.load!(root:, env:)

      refute env.key?("SECRET_KEY_BASE")
      refute env.key?("METRICS_BASIC_AUTH_USERNAME")
      assert_equal "override-key", env["OPENAI_API_KEY"]
    end
  end

  test "is a no-op when dotenv is unavailable" do
    with_temp_env_files(
      ".env" => "PORT=3000\n",
      ".env.local" => "PORT=3200\n",
      ".env.worktree" => "PORT=4100\n"
    ) do |root|
      env = {}

      with_dotenv_available(false) do
        EnvLoader.load!(root:, env:)

        assert_equal({}, env)
        assert_equal "", EnvLoader.shell_exports(root:, env: {})
      end
    end
  end

  private

  def with_dotenv_available(value)
    original_value = EnvLoader::DOTENV_AVAILABLE
    EnvLoader.send(:remove_const, :DOTENV_AVAILABLE)
    EnvLoader.const_set(:DOTENV_AVAILABLE, value)

    yield
  ensure
    EnvLoader.send(:remove_const, :DOTENV_AVAILABLE)
    EnvLoader.const_set(:DOTENV_AVAILABLE, original_value)
  end

  def with_temp_env_files(files)
    Dir.mktmpdir do |root|
      files.each do |filename, content|
        File.write(File.join(root, filename), content)
      end

      yield root
    end
  end
end

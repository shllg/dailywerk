# frozen_string_literal: true

require "dotenv"
require "set"
require "shellwords"

# Loads repository environment files with worktree overrides.
module EnvLoader
  module_function

  ENV_FILENAMES = %w[.env .env.worktree].freeze

  # Loads `.env` first and `.env.worktree` second without clobbering process env.
  #
  # Existing environment variables always win. Variables defined in
  # `.env.worktree` override values coming from `.env`.
  def load!(root:, env: ENV)
    merged_values(root:, env:).each do |key, value|
      env[key] = value
    end
  end

  # Returns shell export commands for repo env files using the same precedence.
  def shell_exports(root:, env: ENV)
    merged_values(root:, env:).map do |key, value|
      %(export #{key}=#{Shellwords.escape(value)})
    end.join("\n")
  end

  def merged_values(root:, env:)
    original_keys = env.keys.to_set
    loaded_values = {}

    env_paths(root).each do |path|
      parse_env_file(path).each do |key, value|
        next if original_keys.include?(key)
        next if value.nil? || value.empty?

        loaded_values[key] = value
      end
    end

    loaded_values
  end
  private_class_method :merged_values

  def env_paths(root)
    ENV_FILENAMES.filter_map do |filename|
      path = File.join(root, filename)
      path if File.file?(path)
    end
  end
  private_class_method :env_paths

  def parse_env_file(path)
    contents = File.open(path, "rb:bom|utf-8", &:read)

    Dotenv::Parser.call(contents, overwrite: true)
  end
  private_class_method :parse_env_file
end

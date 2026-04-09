# frozen_string_literal: true

begin
  require "dotenv"
rescue LoadError
  # dotenv is only installed in development-like environments.
end
require "set"
require "shellwords"

# Loads repository environment files with user and worktree overrides.
module EnvLoader
  module_function

  ENV_FILENAMES = %w[.env .env.local .env.worktree].freeze
  TEMPLATE_FILENAME = ".env.tpl"
  RESETTABLE_STALE_KEYS = %w[VAULT_LOCAL_BASE].freeze
  DOTENV_AVAILABLE = defined?(Dotenv::Parser)

  # Loads `.env`, `.env.local`, and `.env.worktree` without clobbering process env.
  #
  # Existing environment variables always win. Variables defined in
  # `.env.local` override values coming from `.env`, and `.env.worktree`
  # overrides both.
  def load!(root:, env: ENV)
    merged_values(root:, env:, preserve_existing: true).each do |key, value|
      env[key] = value
    end
  end

  # Returns shell export commands for repo env files using the same precedence.
  # Unlike `load!`, this re-exports repo values even when the parent shell
  # already has a value. That keeps `bin/dev`/`bin/test*` aligned with the
  # current `.env` and `.env.worktree` files instead of stale shell state.
  def shell_exports(root:, env: ENV)
    loaded_values = merged_values(root:, env:, preserve_existing: false)
    commands = stale_template_keys(root:, env:, loaded_values:).sort.map do |key|
      "unset #{key}"
    end

    commands.concat(loaded_values.map do |key, value|
      %(export #{key}=#{Shellwords.escape(value)})
    end)

    commands.join("\n")
  end

  def merged_values(root:, env:, preserve_existing:)
    return {} unless DOTENV_AVAILABLE

    original_keys = env.keys.to_set
    loaded_values = {}

    env_paths(root).each do |path|
      parse_env_file(path).each do |key, value|
        next if preserve_existing && original_keys.include?(key)
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

  def stale_template_keys(root:, env:, loaded_values:)
    template_keys(root) & env.keys & RESETTABLE_STALE_KEYS - loaded_values.keys
  end
  private_class_method :stale_template_keys

  def template_keys(root)
    path = File.join(root, TEMPLATE_FILENAME)
    return [] unless File.file?(path)

    File.readlines(path).filter_map do |line|
      line[/^\s*#?\s*([A-Z][A-Z0-9_]*)=/, 1]
    end.uniq
  end
  private_class_method :template_keys

  def parse_env_file(path)
    contents = File.open(path, "rb:bom|utf-8", &:read)

    Dotenv::Parser.call(contents, overwrite: true)
  end
  private_class_method :parse_env_file
end

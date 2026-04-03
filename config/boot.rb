ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.

begin
  require_relative "../lib/env_loader"
  EnvLoader.load!(root: File.expand_path("..", __dir__))
rescue LoadError => error
  raise unless error.path == "dotenv"
end

require "bootsnap/setup" # Speed up boot time by caching expensive operations.

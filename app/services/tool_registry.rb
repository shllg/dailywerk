# frozen_string_literal: true

# Resolves configured tool names into instantiated RubyLLM tool objects.
class ToolRegistry
  REGISTRY = {
    "memory" => "MemoryTool",
    "vault" => "VaultTool"
  }.freeze

  class << self
    # @param names [Array<String>, nil]
    # @param user [User, nil]
    # @param session [Session]
    # @return [Array<RubyLLM::Tool>]
    def build(names, user:, session:)
      Array(names).filter_map do |name|
        klass_name = REGISTRY[name.to_s]
        next unless klass_name

        klass_name.constantize.new(user:, session:)
      end
    end

    # @return [Array<String>]
    def names
      REGISTRY.keys
    end
  end
end

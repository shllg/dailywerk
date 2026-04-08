# frozen_string_literal: true

# Resolves configuration values using a precedence chain:
# ENV > Rails credentials > default (local environments only, unless force_default)
#
# Fiber-safe, read-only after boot. No mutable state.
class ConfigResolver
  NOT_SET = Object.new.freeze

  # @param credentials [ActiveSupport::EncryptedConfiguration] credentials object to query
  def initialize(credentials: Rails.application.credentials)
    @credentials = credentials
  end

  # Resolves a configuration value using the precedence chain.
  # Raises KeyError if no value is found and no default is provided in non-local environments.
  #
  # @param keys [Array<Symbol, String>] credential path keys (e.g., [:workos, :api_key])
  # @param env [String, nil] environment variable name to check first
  # @param default [Object] fallback value if not found in ENV or credentials
  # @param type [Symbol] coercion type: :string, :integer, :boolean
  # @param force_default [Boolean] if true, always use default when no value found
  # @return [Object] resolved and coerced value
  # @raise [KeyError] if no value found and no suitable default
  def resolve(*keys, env: nil, default: NOT_SET, type: :string, force_default: false)
    raw = from_env(env) || from_credentials(keys)

    if raw.nil?
      if default.equal?(NOT_SET)
        raise KeyError, "Missing config: #{env || keys.join('.')}"
      elsif force_default || Rails.env.local?
        raw = default
      else
        raise KeyError, "Missing config: #{env || keys.join('.')} (no default in #{Rails.env})"
      end
    end

    coerce(raw, type)
  end

  # Same as resolve but returns nil instead of raising when no value is found.
  #
  # @param keys [Array<Symbol, String>] credential path keys
  # @param env [String, nil] environment variable name to check first
  # @param default [Object] fallback value if not found
  # @param type [Symbol] coercion type: :string, :integer, :boolean
  # @param force_default [Boolean] if true, always use default when no value found
  # @return [Object, nil] resolved value or nil
  def resolve?(*keys, env: nil, default: NOT_SET, type: :string, force_default: false)
    resolve(*keys, env:, default:, type:, force_default:)
  rescue KeyError
    nil
  end

  private

  # @param key [String, nil]
  # @return [String, nil]
  def from_env(key)
    return nil if key.nil?
    ENV[key].presence # treat "" as missing
  end

  # @param keys [Array<Symbol, String>]
  # @return [Object, nil]
  def from_credentials(keys)
    return nil if keys.empty?
    @credentials.dig(*keys)
  end

  # @param value [Object]
  # @param type [Symbol]
  # @return [Object]
  def coerce(value, type)
    return value unless value.is_a?(String)
    case type
    when :string then value
    when :integer then value.to_i
    when :boolean then ActiveModel::Type::Boolean.new.cast(value)
    else value
    end
  end
end

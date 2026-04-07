# frozen_string_literal: true

require Rails.root.join("lib/production_env_validator")

ProductionEnvValidator.validate!(env: ENV, rails_env: Rails.env)

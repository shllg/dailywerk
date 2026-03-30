# frozen_string_literal: true

RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.dig(:openai_api_key)
  config.model_registry_class = "RubyLLM::ModelRecord"
end

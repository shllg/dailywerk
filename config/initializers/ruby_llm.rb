# frozen_string_literal: true

RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.model_registry_class = "RubyLLM::ModelRecord"
end

# Register newer OpenAI models missing from ruby_llm-responses_api 0.5.3
# (gem's registry stops at GPT-5.2, January 2026 snapshot)
Rails.application.config.after_initialize do
  [
    {
      id: "gpt-5.3", name: "GPT-5.3", family: "gpt-5.3",
      context_window: 400_000, max_output_tokens: 128_000
    },
    {
      id: "gpt-5.4", name: "GPT-5.4", family: "gpt-5.4",
      context_window: 400_000, max_output_tokens: 128_000
    },
    {
      id: "gpt-5.4-pro", name: "GPT-5.4 Pro", family: "gpt-5.4",
      context_window: 400_000, max_output_tokens: 128_000
    }
  ].each do |attrs|
    model = RubyLLM::Model::Info.new(
      provider: "openai_responses",
      modalities: { input: %w[text image], output: [ "text" ] },
      capabilities: %w[streaming function_calling structured_output vision reasoning web_search code_interpreter],
      **attrs
    )
    existing = RubyLLM::Models.instance.all.find { |m| m.id == model.id && m.provider == model.provider }
    RubyLLM::Models.instance.all << model unless existing
  end
end

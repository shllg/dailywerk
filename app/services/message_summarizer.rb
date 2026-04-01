# frozen_string_literal: true

# Condenses large text blocks before they are reused in prompt context.
# Small messages pass straight through; large ones are compressed so they do not
# dominate the compaction prompt's token budget.
class MessageSummarizer
  CHAR_THRESHOLD = 500
  TARGET_CHARS = 400
  DEFAULT_MODEL = "gpt-4o-mini"

  class << self
    # Returns text verbatim when short enough, otherwise summarizes it.
    #
    # @param text [String]
    # @param model [String]
    # @return [String]
    def call(text, model: DEFAULT_MODEL)
      normalized_text = text.to_s
      return normalized_text if normalized_text.blank? || normalized_text.length <= CHAR_THRESHOLD

      response = RubyLLM.chat(model:)
                        .with_temperature(0.1)
                        .ask(summary_prompt(normalized_text))

      response.content.presence || normalized_text.truncate(CHAR_THRESHOLD)
    rescue StandardError
      normalized_text.truncate(CHAR_THRESHOLD)
    end

    private

    # @param text [String]
    # @return [String]
    def summary_prompt(text)
      <<~PROMPT
        Condense this message to about #{TARGET_CHARS} characters. Preserve:
        - Specific facts, names, numbers, dates, URLs, and file paths
        - Key decisions and rationale
        - Code snippets when they matter
        - Error messages
        - Questions or explicit instructions

        Drop greetings, filler, and repeated context. Return only the condensed text.

        Message:
        #{text}
      PROMPT
    end
  end
end

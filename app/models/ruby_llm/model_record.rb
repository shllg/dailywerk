# frozen_string_literal: true

module RubyLLM
  # ActiveRecord-backed registry entry for an LLM model definition.
  class ModelRecord < ApplicationRecord
    self.table_name = "ruby_llm_models"

    acts_as_model chats: :sessions, chat_class: "Session"
  end
end

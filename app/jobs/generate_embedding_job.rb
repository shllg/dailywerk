# frozen_string_literal: true

# Generates embeddings for persisted records that expose searchable content.
class GenerateEmbeddingJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  EMBEDDABLE_MODELS = {
    "VaultChunk" => VaultChunk
  }.freeze

  queue_as :default

  good_job_control_concurrency_with(
    perform_limit: 3,
    key: -> { "generate_embedding:#{arguments[0]}:#{arguments[1]}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param model_class_name [String]
  # @param record_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(model_class_name, record_id, workspace_id:)
    model_class = EMBEDDABLE_MODELS.fetch(model_class_name) do
      raise ArgumentError, "Unsupported embeddable model: #{model_class_name}"
    end

    record = model_class.find(record_id)
    vector = RubyLLM.embed(record.content.to_s).vectors
    vector = vector.first if vector.is_a?(Array) && vector.first.is_a?(Array)
    record.update!(embedding: vector)
  end
end

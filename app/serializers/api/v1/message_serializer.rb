# frozen_string_literal: true

module Api
  module V1
    # Serializes persisted chat messages for API responses.
    class MessageSerializer
      class << self
        # @param message [Message]
        # @return [Hash]
        def summary(message)
          {
            id: message.id,
            role: message.role,
            content: message.content.to_s,
            timestamp: message.created_at.iso8601
          }
        end
      end
    end
  end
end

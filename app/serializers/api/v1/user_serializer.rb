# frozen_string_literal: true

module Api
  module V1
    # Serializes user payloads returned by the API.
    class UserSerializer
      class << self
        # @param user [User]
        # @return [Hash]
        def summary(user)
          {
            id: user.id,
            email: user.email,
            name: user.name
          }
        end
      end
    end
  end
end

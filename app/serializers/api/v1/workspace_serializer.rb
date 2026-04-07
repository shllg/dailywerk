# frozen_string_literal: true

module Api
  module V1
    # Serializes workspace payloads returned by the API.
    class WorkspaceSerializer
      class << self
        # @param workspace [Workspace]
        # @return [Hash]
        def summary(workspace)
          {
            id: workspace.id,
            name: workspace.name
          }
        end
      end
    end
  end
end

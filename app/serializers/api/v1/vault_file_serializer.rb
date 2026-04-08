# frozen_string_literal: true

module Api
  module V1
    # Serializes vault file payloads for API responses.
    class VaultFileSerializer
      class << self
        # @param file [VaultFile]
        # @return [Hash]
        def summary(file)
          {
            id: file.id,
            path: file.path,
            file_type: file.file_type,
            title: file.title,
            content_hash: file.content_hash,
            size_bytes: file.size_bytes,
            tags: file.tags,
            updated_at: file.updated_at.iso8601
          }
        end

        # @param file [VaultFile]
        # @param vault_service [VaultFileService] the service to read file content
        # @return [Hash]
        def with_content(file, vault_service: nil)
          base = summary(file)

          # For binary file types, return null content with content_type hint
          if binary_file_type?(file.file_type)
            base.merge(
              content: nil,
              content_type: file.content_type
            )
          else
            # For text types, read and return the content
            content = vault_service&.read(file.path)
            base.merge(content: content)
          end
        end

        private

        # @param file_type [String]
        # @return [Boolean]
        def binary_file_type?(file_type)
          %w[image pdf audio video].include?(file_type)
        end
      end
    end
  end
end

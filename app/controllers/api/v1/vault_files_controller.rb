# frozen_string_literal: true

module Api
  module V1
    # Browse and search vault files.
    class VaultFilesController < ApplicationController
      include RequireWorkspaceAdmin

      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

      # Lists files in the vault, optionally filtered by path prefix.
      # Excludes internal `_dailywerk/` files from results.
      #
      # @return [void]
      def index
        vault = find_vault(params[:vault_id])
        files = vault.vault_files
                     .where.not("path LIKE ?", "_dailywerk/%")
                     .order(updated_at: :desc)

        # Apply path prefix filter if provided
        if params[:path].present?
          prefix = sanitize_like_pattern(params[:path])
          files = files.where("path LIKE ?", "#{prefix}%")
        end

        render json: {
          files: files.limit(200).map { |file| VaultFileSerializer.summary(file) }
        }
      end

      # Shows a single file with its content (text types only).
      # Binary files return metadata with content: null.
      #
      # @return [void]
      def show
        vault = find_vault(params[:vault_id])
        file = vault.vault_files.find(params[:id])

        vault_service = VaultFileService.new(vault: vault)

        render json: {
          file: VaultFileSerializer.with_content(file, vault_service: vault_service)
        }
      end

      # Fulltext-only search within the vault.
      # Uses PostgreSQL tsvector, no embedding (avoids blocking I/O in Falcon).
      # Excludes internal `_dailywerk/` files from results.
      #
      # @return [void]
      def search
        vault = find_vault(params[:id])
        query = params[:query].to_s.strip

        if query.blank?
          render json: { error: "Query cannot be blank" }, status: :bad_request
          return
        end

        if query.length > 1000
          render json: { error: "Query is too long" }, status: :bad_request
          return
        end

        # Fulltext search through vault_chunks, return distinct files
        quoted_tsquery = ActiveRecord::Base.send(
          :sanitize_sql_array,
          [ "plainto_tsquery('english', ?)", query ]
        )

        file_ids = vault.vault_chunks
                        .where("tsv @@ plainto_tsquery('english', ?)", query)
                        .where.not("vault_files.path LIKE ?", "_dailywerk/%")
                        .joins(:vault_file)
                        .order(Arel.sql("ts_rank(vault_chunks.tsv, #{quoted_tsquery}) DESC"))
                        .limit(20)
                        .pluck(:vault_file_id)
                        .uniq

        files = vault.vault_files.where(id: file_ids)

        render json: {
          query: query,
          files: files.map { |file| VaultFileSerializer.summary(file) }
        }
      end

      private

      # @param vault_id [String]
      # @return [Vault]
      def find_vault(vault_id)
        Current.workspace.vaults.find(vault_id)
      end

      # @param pattern [String]
      # @return [String]
      def sanitize_like_pattern(pattern)
        ActiveRecord::Base.sanitize_sql_like(pattern.to_s.strip)
      end

      # @param error [ActiveRecord::RecordNotFound]
      # @return [void]
      def render_not_found(error)
        render json: { error: error.message }, status: :not_found
      end
    end
  end
end

# frozen_string_literal: true

require "set"

# Pushes local vault changes to S3 and refreshes vault size metadata.
class VaultS3SyncJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    total_limit: 3,
    key: -> { "vault_s3_sync:#{arguments[0]}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param vault_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(vault_id, workspace_id:)
    vault = Vault.find(vault_id)
    file_service = VaultFileService.new(vault: vault)
    s3_service = VaultS3Service.new(vault)
    local_paths = file_service.list

    push_changed_files(vault, file_service, s3_service, local_paths)
    cleanup_removed_files(vault, s3_service, local_paths)
    refresh_metrics(vault, file_service, local_paths)
  end

  private

  # @param vault [Vault]
  # @param file_service [VaultFileService]
  # @param s3_service [VaultS3Service]
  # @param local_paths [Array<String>]
  # @return [void]
  def push_changed_files(vault, file_service, s3_service, local_paths)
    local_paths.each do |relative_path|
      vault_file = vault.vault_files.find_by(path: relative_path)
      next unless vault_file.nil? || vault_file.synced_at.nil? || vault_file.last_modified&.>(vault_file.synced_at)

      s3_service.put_object(relative_path, file_service.read(relative_path))
      vault_file&.update!(synced_at: Time.current)
    rescue VaultFileService::PathTraversalError
      next
    end
  end

  # @param vault [Vault]
  # @param s3_service [VaultS3Service]
  # @param local_paths [Array<String>]
  # @return [void]
  def cleanup_removed_files(vault, s3_service, local_paths)
    disk_paths = Set.new(local_paths)
    remote_paths = Set.new(s3_service.list_relative_keys.reject { |path| path.blank? || path == ".keep" })

    (remote_paths - disk_paths).each do |path|
      s3_service.delete_object(path)
    end

    vault.vault_files.where.not(path: disk_paths.to_a).find_each(&:destroy!)
  end

  # @param vault [Vault]
  # @param file_service [VaultFileService]
  # @param local_paths [Array<String>]
  # @return [void]
  def refresh_metrics(vault, file_service, local_paths)
    total_size = local_paths.sum do |path|
      File.size(file_service.resolve_safe_path(path))
    rescue VaultFileService::PathTraversalError
      0
    end

    status = total_size >= vault.max_size_bytes ? "suspended" : "active"

    vault.update!(
      file_count: local_paths.size,
      current_size_bytes: total_size,
      status: status,
      error_message: status == "suspended" ? "Vault size exceeds #{vault.max_size_bytes / 1.gigabyte} GB limit" : nil
    )
  end
end

# frozen_string_literal: true

require "fileutils"

# Creates, seeds, and destroys vault storage for one workspace.
class VaultManager
  # @param workspace [Workspace]
  def initialize(workspace:)
    @workspace = workspace
  end

  # Creates a new vault, seeds `_dailywerk/`, and prepares remote storage.
  # Immediately indexes seed files so they appear in the API without waiting
  # for the file watcher.
  #
  # @param name [String]
  # @param vault_type [String]
  # @return [Vault]
  def create(name:, vault_type: "native")
    with_workspace_context do
      slug = next_available_slug(name)
      vault = Vault.create!(
        workspace: @workspace,
        name:,
        slug:,
        vault_type:,
        status: "active"
      )

      FileUtils.mkdir_p(local_path_for(slug))
      seed_default_files(vault)
      sync_seed_files(vault)
      enqueue_seed_file_jobs(vault)
      refresh_metrics(vault)
      vault
    end
  end

  # Deletes the vault's local checkout, remote objects, and database row.
  # Stops any running sync process first.
  #
  # @param vault [Vault]
  # @return [void]
  def destroy(vault)
    with_workspace_context do
      # Stop any running sync process first
      if vault.sync_config&.process_status.in?(%w[starting running])
        ObsidianSyncManager.new(vault.sync_config).stop!
      end

      VaultS3Service.new(vault).delete_prefix!
      FileUtils.rm_rf(local_path_for(vault.slug))
      vault.destroy!
    end
  end

  # Enqueues structure analysis for an imported or existing vault.
  #
  # @param vault [Vault]
  # @return [void]
  def analyze_and_guide(vault)
    VaultStructureAnalysisJob.perform_later(vault.id, workspace_id: vault.workspace_id)
  end

  private

  # @param vault [Vault]
  # @return [void]
  def seed_default_files(vault)
    file_service = VaultFileService.new(vault:)
    file_service.write("_dailywerk/README.md", template_content("vault_readme_default.md"))
    file_service.write("_dailywerk/vault-guide.md", template_content("vault_guide_default.md"))
  end

  # @param vault [Vault]
  # @return [void]
  def sync_seed_files(vault)
    file_service = VaultFileService.new(vault:)
    s3_service = VaultS3Service.new(vault)
    s3_service.ensure_prefix!

    %w[_dailywerk/README.md _dailywerk/vault-guide.md].each do |path|
      s3_service.put_object(path, file_service.read(path))
    end
  end

  # Immediately enqueue indexing jobs for seed files so they appear
  # in the API without waiting for the file watcher.
  #
  # @param vault [Vault]
  # @return [void]
  def enqueue_seed_file_jobs(vault)
    %w[_dailywerk/README.md _dailywerk/vault-guide.md].each do |path|
      VaultFileChangedJob.perform_later(vault.id, path, "create", workspace_id: vault.workspace_id)
    end
  end

  # @param vault [Vault]
  # @return [void]
  def refresh_metrics(vault)
    file_service = VaultFileService.new(vault:)
    paths = file_service.list
    size = paths.sum { |path| File.size(file_service.resolve_safe_path(path)) }

    vault.update!(file_count: paths.size, current_size_bytes: size)
  end

  # @param filename [String]
  # @return [String]
  def template_content(filename)
    Rails.root.join("lib/templates/#{filename}").read
  end

  # @param name [String]
  # @return [String]
  def next_available_slug(name)
    base = name.to_s.parameterize.presence || "vault"
    slug = base
    suffix = 2

    while @workspace.vaults.where(slug:).exists?
      slug = "#{base}-#{suffix}"
      suffix += 1
    end

    slug
  end

  # @param slug [String]
  # @return [String]
  def local_path_for(slug)
    safe_slug = slug.to_s
    raise ArgumentError, "invalid vault slug" unless safe_slug.match?(/\A[a-z0-9][a-z0-9-]*\z/)

    File.join(
      Rails.configuration.x.vault_local_base.presence || Vault::DEFAULT_LOCAL_BASE,
      @workspace.id,
      "vaults",
      safe_slug
    )
  end

  # @yield Runs with Current.workspace set to the manager workspace.
  # @return [Object]
  def with_workspace_context
    previous_user = Current.user
    previous_workspace = Current.workspace
    Current.user ||= @workspace.owner
    Current.workspace = @workspace
    yield
  ensure
    Current.user = previous_user
    Current.workspace = previous_workspace
  end
end

# frozen_string_literal: true

# Watches active vault directories and debounces file system events into jobs.
# Periodically rescans for new vaults created while running.
class VaultWatcher
  DEBOUNCE_SECONDS = 2
  RESCAN_INTERVAL_SECONDS = 30

  # @return [void]
  def run
    require "rb-inotify"

    Rails.logger.info("[VaultWatcher] Starting")
    @notifier = INotify::Notifier.new
    @pending = {}
    @move_sources = {}
    @watched_dirs = {}
    @last_rescan = Time.current

    setup_watches
    run_loop
  rescue Interrupt
    Rails.logger.info("[VaultWatcher] Stopping")
  ensure
    @notifier&.close
  end

  private

  # @return [void]
  def setup_watches
    Current.without_workspace_scoping do
      Vault.active.find_each do |vault|
        next unless Dir.exist?(vault.local_path)

        watch_vault(vault)
      end
    end
  end

  # @param vault [Vault]
  # @return [void]
  def watch_vault(vault)
    directories = [ vault.local_path ] + Dir.glob(File.join(vault.local_path, "**/")).select { |path| File.directory?(path) }
    directories.uniq.each { |directory| add_watch(vault, directory) }
  end

  # @param vault [Vault]
  # @param directory [String]
  # @return [void]
  def add_watch(vault, directory)
    return if @watched_dirs.key?(directory)

    @watched_dirs[directory] = true
    @notifier.watch(directory, :modify, :create, :delete, :moved_to, :moved_from) do |event|
      handle_raw_event(vault, directory, event)
    end
  end

  # @param vault [Vault]
  # @param directory [String]
  # @param event [Object]
  # @return [void]
  def handle_raw_event(vault, directory, event)
    name = event.name.to_s
    return if name.blank? || name.start_with?(".")

    absolute_name = event.absolute_name || File.join(directory, name)
    relative_path = absolute_name.delete_prefix("#{vault.local_path}/")
    return if relative_path.blank? || ignored_path?(relative_path)

    handle_event(vault, event, relative_path, absolute_name)
  end

  # @param vault [Vault]
  # @param event [Object]
  # @param relative_path [String]
  # @param absolute_name [String]
  # @return [void]
  def handle_event(vault, event, relative_path, absolute_name)
    flags = event.flags

    if flags.include?(:create) && flags.include?(:isdir)
      add_watch(vault, absolute_name) if Dir.exist?(absolute_name)
      return
    end

    if flags.include?(:moved_from)
      @move_sources[event.cookie] = {
        vault_id: vault.id,
        workspace_id: vault.workspace_id,
        path: relative_path,
        at: Time.current
      }
    elsif flags.include?(:moved_to)
      source = @move_sources.delete(event.cookie)
      if source
        @pending["move:#{vault.id}:#{relative_path}"] = {
          vault_id: vault.id,
          workspace_id: vault.workspace_id,
          path: relative_path,
          old_path: source[:path],
          event_type: "move",
          at: Time.current
        }
      else
        @pending["#{vault.id}:#{relative_path}"] = {
          vault_id: vault.id,
          workspace_id: vault.workspace_id,
          path: relative_path,
          event_type: "create",
          at: Time.current
        }
      end
    elsif flags.include?(:delete)
      @pending["#{vault.id}:#{relative_path}"] = {
        vault_id: vault.id,
        workspace_id: vault.workspace_id,
        path: relative_path,
        event_type: "delete",
        at: Time.current
      }
    else
      @pending["#{vault.id}:#{relative_path}"] = {
        vault_id: vault.id,
        workspace_id: vault.workspace_id,
        path: relative_path,
        event_type: "modify",
        at: Time.current
      }
    end
  end

  # @return [void]
  def run_loop
    loop do
      readable, = IO.select([ @notifier.to_io ], nil, nil, DEBOUNCE_SECONDS)
      @notifier.process if readable
      flush_pending
      expire_orphaned_move_sources
      scan_for_new_vaults
    end
  end

  # @return [void]
  def flush_pending
    cutoff = Time.current - DEBOUNCE_SECONDS
    to_process = @pending.select { |_, entry| entry[:at] <= cutoff }
    to_process.each_key { |key| @pending.delete(key) }

    to_process.each_value do |entry|
      VaultFileChangedJob.perform_later(
        entry[:vault_id],
        entry[:path],
        entry[:event_type],
        workspace_id: entry[:workspace_id],
        old_path: entry[:old_path]
      )
    end
  end

  # @return [void]
  def expire_orphaned_move_sources
    cutoff = Time.current - (DEBOUNCE_SECONDS * 2)

    @move_sources.to_a.each do |cookie, source|
      next if source[:at] > cutoff

      @pending["#{source[:vault_id]}:#{source[:path]}"] = source.merge(event_type: "delete")
      @move_sources.delete(cookie)
    end
  end

  # Periodically scan for new vaults created while watcher is running.
  # Attaches inotify watches to vaults that don't have them yet.
  #
  # @return [void]
  def scan_for_new_vaults
    return if Time.current - @last_rescan < RESCAN_INTERVAL_SECONDS

    @last_rescan = Time.current
    new_vault_count = 0

    Current.without_workspace_scoping do
      Vault.active.find_each do |vault|
        next unless Dir.exist?(vault.local_path)
        next if vault_already_watched?(vault)

        watch_vault(vault)
        new_vault_count += 1
      end
    end

    Rails.logger.info("[VaultWatcher] Rescanned: attached #{new_vault_count} new vaults") if new_vault_count > 0
  end

  # @param vault [Vault]
  # @return [Boolean]
  def vault_already_watched?(vault)
    @watched_dirs.key?(vault.local_path)
  end

  # @param path [String]
  # @return [Boolean]
  def ignored_path?(path)
    path.start_with?(".obsidian/") ||
      path.start_with?(".trash/") ||
      path.split("/").any? { |part| part.start_with?(".") }
  end
end

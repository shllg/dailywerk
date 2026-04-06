# frozen_string_literal: true

module WorkosSync
  # Syncs user attributes from a WorkOS webhook event.
  #
  # Finds the user by workos_id and updates email/name if changed.
  # Idempotent — safe to process the same event multiple times.
  class UserSyncService
    # @param data [Hash] permitted webhook event data with "id", "email", "first_name", "last_name"
    def initialize(data)
      @data = data
    end

    # @return [void]
    def call
      user = User.find_by(workos_id: @data["id"])
      unless user
        Rails.logger.info "WorkosSync::UserSyncService: no user with workos_id #{@data['id']}"
        return
      end

      attrs = {}
      new_name = build_name
      attrs[:name] = new_name if new_name.present? && new_name != user.name
      attrs[:email] = @data["email"] if @data["email"].present? && @data["email"] != user.email

      if attrs.any?
        user.update!(attrs)
        Rails.logger.info "WorkosSync::UserSyncService: updated user #{user.id}: #{attrs.keys.join(', ')}"
      end
    end

    private

    # @return [String, nil]
    def build_name
      [ @data["first_name"], @data["last_name"] ].compact_blank.join(" ").presence
    end
  end
end

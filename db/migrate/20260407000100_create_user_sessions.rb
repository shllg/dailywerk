# frozen_string_literal: true

# Stores server-side session state for WorkOS authentication.
# Each record holds an encrypted refresh token and maps to an HttpOnly
# session cookie in the browser. Not workspace-scoped — a user session
# precedes workspace selection.
class CreateUserSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :user_sessions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: true
      t.text       :refresh_token
      t.string     :workos_session_id
      t.datetime   :expires_at, null: false
      t.datetime   :revoked_at
      t.string     :ip_address
      t.string     :user_agent
      t.timestamps
    end

    add_index :user_sessions, :workos_session_id, unique: true,
              where: "workos_session_id IS NOT NULL"
  end
end

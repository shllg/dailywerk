# frozen_string_literal: true

require_relative "../../lib/rls_migration_helpers"

class CreateUserProfiles < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :user_profiles, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.text :synthesized_profile
      t.datetime :profile_synthesized_at
      t.timestamps
      t.index %i[user_id workspace_id], unique: true
    end

    safety_assured { enable_workspace_rls!(:user_profiles) }
  end

  def down
    safety_assured { disable_workspace_rls!(:user_profiles) }
    drop_table :user_profiles
  end
end

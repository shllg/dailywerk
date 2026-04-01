# Rails Model Skill

Copy-paste templates for creating a workspace-scoped model. Adapt names as needed.

## Migration

```ruby
require_relative "../../lib/rls_migration_helpers"

class CreateThings < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :things, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :status, null: false, default: "active"
      t.timestamps

      t.index %i[workspace_id name], unique: true
      t.index %i[workspace_id status]
    end

    safety_assured { enable_workspace_rls!(:things) }
  end

  def down
    safety_assured { disable_workspace_rls!(:things) }
    drop_table :things
  end
end
```

For child tables (no `workspace_id` column, inherits via parent FK):

```ruby
safety_assured do
  enable_parent_rls!(:child_table, parent_table: :things, parent_fk: :thing_id)
end
```

Key points:
- `id: :uuid, default: -> { "gen_random_uuid_v7()" }` — UUIDv7 PK, always
- FK columns: `type: :uuid`
- Index every FK and every WHERE column
- Concurrent indexes on existing tables: `add_index :things, :col, algorithm: :concurrently`
- Wrap RLS DDL in `safety_assured { }` — strong_migrations cannot analyse it
- Schema format: `db/structure.sql` (not `schema.rb`) — set in `config/application.rb`

## Model

```ruby
# frozen_string_literal: true

# One-line doc: what this model represents.
class Thing < ApplicationRecord
  include WorkspaceScoped

  belongs_to :other_model, inverse_of: :things
  has_many :child_models, dependent: :destroy, inverse_of: :thing

  validates :name, presence: true, uniqueness: { scope: :workspace_id }
  validates :status, presence: true, inclusion: { in: %w[active archived] }

  scope :active, -> { where(status: "active") }
end
```

Key points:
- Always `include WorkspaceScoped` — adds `belongs_to :workspace`, default_scope, and before_validation
- Always `inverse_of:` on associations — prevents extra queries and N+1 issues
- `uniqueness: { scope: :workspace_id }` when a field must be unique within a workspace
- YARD comment on the class and non-trivial public methods

## Test

```ruby
# frozen_string_literal: true

require "test_helper"

class ThingTest < ActiveSupport::TestCase
  test "belongs to workspace and is isolated from other workspaces" do
    user_one, workspace_one = create_user_with_workspace
    user_two, workspace_two = create_user_with_workspace(
      email: "other-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    with_current_workspace(workspace_one, user: user_one) do
      Thing.create!(name: "Widget")
      assert_equal 1, Thing.count
    end

    with_current_workspace(workspace_two, user: user_two) do
      assert_equal 0, Thing.count
    end
  end

  test "requires name" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      thing = Thing.new(name: "")
      assert_not thing.valid?
      assert_includes thing.errors[:name], "can't be blank"
    end
  end
end
```

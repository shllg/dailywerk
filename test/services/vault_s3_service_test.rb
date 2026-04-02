# frozen_string_literal: true

require "test_helper"

class VaultS3ServiceTest < ActiveSupport::TestCase
  test "initializes an S3 client for the vault" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "knowledge-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )

      service = VaultS3Service.new(vault)

      assert_instance_of Aws::S3::Client, service.instance_variable_get(:@client)
      refute service.send(:s3_config)[:require_https_for_sse_cpk]
    end
  end
end

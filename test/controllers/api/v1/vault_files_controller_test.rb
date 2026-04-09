# frozen_string_literal: true

require "test_helper"

class Api::V1::VaultFilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user, @workspace = create_user_with_workspace
    @original_vault_local_base = Rails.configuration.x.vault_local_base
    @temp_local_base = Dir.mktmpdir("vault-files-test")
    Rails.configuration.x.vault_local_base = @temp_local_base
    @vault = create_vault!(name: "Test Vault")
  end

  teardown do
    Rails.configuration.x.vault_local_base = @original_vault_local_base
    FileUtils.rm_rf(@temp_local_base) if @temp_local_base
  end

  test "index lists files in vault excluding internal paths" do
    create_vault_file!(@vault, path: "notes/alpha.md")
    create_vault_file!(@vault, path: "notes/beta.md")
    create_vault_file!(@vault, path: "_dailywerk/internal.md")

    get "/api/v1/vaults/#{@vault.id}/files", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal 2, body["files"].length
    paths = body["files"].map { |f| f["path"] }

    assert_includes paths, "notes/alpha.md"
    assert_includes paths, "notes/beta.md"
    refute_includes paths, "_dailywerk/internal.md"
  end

  test "index filters by path prefix" do
    create_vault_file!(@vault, path: "notes/alpha.md")
    create_vault_file!(@vault, path: "projects/beta.md")

    get "/api/v1/vaults/#{@vault.id}/files?path=notes", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal 1, body["files"].length
    assert_equal "notes/alpha.md", body["files"].first["path"]
  end

  test "show returns file with content for text files" do
    file = create_vault_file!(@vault, path: "notes/readme.md", file_type: "markdown")

    # Write actual content to disk
    file_service = VaultFileService.new(vault: @vault)
    file_service.write("notes/readme.md", "# Hello World\n\nThis is a test.")

    get "/api/v1/vaults/#{@vault.id}/files/#{file.id}", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal "notes/readme.md", body["file"]["path"]
    assert_equal "# Hello World\n\nThis is a test.", body["file"]["content"]
    assert_equal "markdown", body["file"]["file_type"]
  end

  test "show returns null content for binary files" do
    file = create_vault_file!(@vault, path: "images/photo.png", file_type: "image")

    get "/api/v1/vaults/#{@vault.id}/files/#{file.id}", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_nil body["file"]["content"]
    assert_equal "image/png", body["file"]["content_type"]
  end

  test "search returns matching files via fulltext" do
    file = create_vault_file!(@vault, path: "notes/important.md")

    # Create a chunk with searchable content
    with_current_workspace(@workspace, user: @user) do
      VaultChunk.create!(
        vault_file: file,
        workspace: @workspace,
        file_path: "notes/important.md",
        chunk_idx: 0,
        content: "This document contains critical security information",
        tsv: "'critical':3 'document':1 'secur':5"
      )
    end

    get "/api/v1/vaults/#{@vault.id}/search?query=security", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal "security", body["query"]
    assert_equal 1, body["files"].length
    assert_equal "notes/important.md", body["files"].first["path"]
  end

  test "search excludes internal _dailywerk files" do
    public_file = create_vault_file!(@vault, path: "notes/public.md")
    internal_file = create_vault_file!(@vault, path: "_dailywerk/secret.md")

    with_current_workspace(@workspace, user: @user) do
      VaultChunk.create!(
        vault_file: public_file,
        workspace: @workspace,
        file_path: "notes/public.md",
        chunk_idx: 0,
        content: "public searchable content",
        tsv: "'content':3 'public':1 'searchabl':2"
      )
      VaultChunk.create!(
        vault_file: internal_file,
        workspace: @workspace,
        file_path: "_dailywerk/secret.md",
        chunk_idx: 0,
        content: "secret searchable content",
        tsv: "'content':3 'secret':1 'searchabl':2"
      )
    end

    get "/api/v1/vaults/#{@vault.id}/search?query=content", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    paths = body["files"].map { |f| f["path"] }

    assert_includes paths, "notes/public.md"
    refute_includes paths, "_dailywerk/secret.md"
  end

  test "search validates query presence" do
    get "/api/v1/vaults/#{@vault.id}/search?query=", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :bad_request
    body = JSON.parse(response.body)

    assert_equal "Query cannot be blank", body["error"]
  end

  test "search validates query length" do
    get "/api/v1/vaults/#{@vault.id}/search?query=#{('a' * 1001)}", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :bad_request
    body = JSON.parse(response.body)

    assert_equal "Query is too long", body["error"]
  end

  test "returns 404 for file not in vault" do
    other_vault = create_vault!(name: "Other Vault")
    other_file = create_vault_file!(other_vault, path: "other.md")

    get "/api/v1/vaults/#{@vault.id}/files/#{other_file.id}", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :not_found
  end

  private

  def create_vault!(name:)
    with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: name,
        slug: "#{name.parameterize}-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end
  end

  def create_vault_file!(vault, path:, title: nil, file_type: "markdown")
    with_current_workspace(@workspace, user: @user) do
      VaultFile.create!(
        vault: vault,
        path: path,
        title: title,
        file_type: file_type,
        content_type: file_type == "image" ? "image/png" : "text/markdown",
        content_hash: SecureRandom.hex(8)
      )
    end
  end
end

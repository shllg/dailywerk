# frozen_string_literal: true

require "aws-sdk-s3"
require "digest"
require "fileutils"
require "uri"

# Wraps the S3 interactions for one vault's canonical remote store.
class VaultS3Service
  ALLOWED_KEY_PATTERN = /\A[a-zA-Z0-9\/\-_\. ]+\z/.freeze

  # @param vault [Vault]
  def initialize(vault)
    @vault = vault
    @bucket = configured_bucket
    @client = Aws::S3::Client.new(s3_config)
  end

  # Writes an object into the vault prefix.
  #
  # @param path [String]
  # @param body [String]
  # @return [void]
  def put_object(path, body)
    @client.put_object(bucket: @bucket, key: key_for(path), body:, **sse_c_headers)
  end

  # Reads an object from the vault prefix.
  #
  # @param path [String]
  # @return [String, nil]
  def get_object(path)
    @client.get_object(bucket: @bucket, key: key_for(path), **sse_c_headers).body.read
  rescue Aws::S3::Errors::NoSuchKey
    nil
  end

  # Deletes an object from the vault prefix.
  #
  # @param path [String]
  # @return [void]
  def delete_object(path)
    @client.delete_object(bucket: @bucket, key: key_for(path))
  end

  # Creates a sentinel object so the vault prefix exists remotely.
  #
  # @return [void]
  def ensure_prefix!
    put_object(".keep", +"")
  end

  # Deletes all objects under the vault prefix.
  #
  # @return [void]
  def delete_prefix!
    keys = list_full_keys
    return if keys.empty?

    @client.delete_objects(
      bucket: @bucket,
      delete: {
        objects: keys.map { |key| { key: key } }
      }
    )
  end

  # Downloads the remote vault to the local checkout.
  #
  # @return [void]
  def checkout_to_local!
    file_service = VaultFileService.new(vault: @vault)
    list_relative_keys.each do |relative_path|
      next if relative_path == ".keep"

      file_service.write(relative_path, get_object(relative_path))
    end
  end

  # Copies the current object payload to another key for future versioning.
  #
  # @param path [String]
  # @param version_key [String]
  # @return [void]
  def copy_to_version(path, version_key)
    body = get_object(path)
    return if body.nil?

    @client.put_object(
      bucket: @bucket,
      key: sanitize_s3_key(version_key),
      body:,
      **sse_c_headers
    )
  end

  # Reads an object by absolute S3 key.
  #
  # @param key [String]
  # @return [String]
  def get_by_key(key)
    @client.get_object(bucket: @bucket, key: sanitize_s3_key(key), **sse_c_headers).body.read
  end

  # @return [Array<String>] relative keys stored under the vault prefix
  def list_relative_keys
    list_full_keys.map { |key| key.delete_prefix("#{prefix}/") }
  end

  private

  # @return [String]
  def prefix
    @vault.s3_prefix
  end

  # @param path [String]
  # @return [String]
  def key_for(path)
    relative_path = sanitize_s3_key(path.to_s.sub(%r{\A/+}, ""))
    "#{prefix}/#{relative_path}"
  end

  # @param key [String]
  # @return [String]
  def sanitize_s3_key(key)
    value = key.to_s

    raise ArgumentError, "S3 key must not be blank" if value.blank?
    raise ArgumentError, "S3 key contains invalid characters" unless value.match?(ALLOWED_KEY_PATTERN)
    raise ArgumentError, "S3 key contains traversal segments" if value.split("/").any? { |part| part == ".." }

    value
  end

  # @return [Hash]
  def sse_c_headers
    return {} unless sse_c_enabled?

    key = @vault.sse_customer_key

    {
      sse_customer_algorithm: "AES256",
      sse_customer_key: key,
      sse_customer_key_md5: Digest::MD5.base64digest(key)
    }
  end

  # SSE-CPK is enabled unless explicitly disabled via config.
  # Production/staging: always true (default). Dev/test: false (RustFS has no SSE-CPK support).
  #
  # @return [Boolean]
  def sse_c_enabled?
    Rails.configuration.x.vault_s3.require_https_for_sse_cpk != false
  end

  # @return [String]
  def configured_bucket
    Rails.configuration.x.vault_s3.bucket
  end

  # @return [Hash]
  def s3_config
    cfg = Rails.configuration.x.vault_s3
    {
      access_key_id: cfg.access_key,
      secret_access_key: cfg.secret_key,
      region: cfg.region,
      endpoint: cfg.endpoint,
      force_path_style: cfg.force_path_style
    }.compact
  end

  # @return [Array<String>]
  def list_full_keys
    keys = []
    continuation_token = nil

    loop do
      response = @client.list_objects_v2(
        bucket: @bucket,
        prefix: "#{prefix}/",
        continuation_token:
      )
      keys.concat(response.contents.map(&:key))

      break unless response.is_truncated

      continuation_token = response.next_continuation_token
    end

    keys
  end
end

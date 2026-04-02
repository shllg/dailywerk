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
    key = @vault.sse_customer_key

    {
      sse_customer_algorithm: "AES256",
      sse_customer_key: key,
      sse_customer_key_md5: Digest::MD5.base64digest(key)
    }
  end

  # @return [String]
  def configured_bucket
    Rails.configuration.x.vault_s3_bucket.presence ||
      ENV["S3_BUCKET"].presence ||
      Rails.application.credentials.dig(:hetzner_s3, :bucket) ||
      Rails.application.credentials.dig(:rustfs, :bucket) ||
      Rails.application.credentials.dig(:vault_s3, :bucket) ||
      ENV.fetch("RUSTFS_BUCKET", "dailywerk-dev")
  end

  # @return [Hash]
  def s3_config
    {
      access_key_id: ENV["AWS_ACCESS_KEY_ID"].presence ||
        Rails.application.credentials.dig(:hetzner_s3, :access_key) ||
        Rails.application.credentials.dig(:rustfs, :access_key) ||
        Rails.application.credentials.dig(:vault_s3, :access_key_id) ||
        ENV.fetch("RUSTFS_ACCESS_KEY", "rustfsadmin"),
      secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"].presence ||
        Rails.application.credentials.dig(:hetzner_s3, :secret_key) ||
        Rails.application.credentials.dig(:rustfs, :secret_key) ||
        Rails.application.credentials.dig(:vault_s3, :secret_access_key) ||
        ENV.fetch("RUSTFS_SECRET_KEY", "rustfsadmin"),
      region: ENV["AWS_REGION"].presence ||
        Rails.configuration.x.vault_s3_region.presence ||
        Rails.application.credentials.dig(:hetzner_s3, :region) ||
        Rails.application.credentials.dig(:rustfs, :region) ||
        Rails.application.credentials.dig(:vault_s3, :region) ||
        "us-east-1",
      endpoint: ENV["AWS_ENDPOINT"].presence ||
        Rails.configuration.x.vault_s3_endpoint.presence ||
        Rails.application.credentials.dig(:hetzner_s3, :endpoint) ||
        Rails.application.credentials.dig(:rustfs, :endpoint) ||
        Rails.application.credentials.dig(:vault_s3, :endpoint),
      force_path_style: ActiveModel::Type::Boolean.new.cast(ENV.fetch("AWS_FORCE_PATH_STYLE", "true")),
      require_https_for_sse_cpk: require_https_for_sse_cpk?
    }.compact
  end

  # @return [Boolean]
  def require_https_for_sse_cpk?
    configured_value = Rails.configuration.x.vault_s3_require_https_for_sse_cpk
    return configured_value unless configured_value.nil?

    endpoint = Rails.configuration.x.vault_s3_endpoint.presence
    return true if endpoint.blank?

    URI.parse(endpoint).scheme != "http"
  rescue URI::InvalidURIError
    true
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

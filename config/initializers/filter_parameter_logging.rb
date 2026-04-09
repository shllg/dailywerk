# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :sse_customer_key, :encryption_key_enc,
  :refresh_token, :authorization_code, :code_verifier,
  # Obsidian Sync credentials (both _enc DB columns and plain param names)
  :obsidian_email_enc, :obsidian_password_enc, :obsidian_encryption_password_enc,
  :obsidian_email, :obsidian_password, :obsidian_encryption_password
]

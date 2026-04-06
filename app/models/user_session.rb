# frozen_string_literal: true

# Server-side session for WorkOS authentication.
#
# Stores an encrypted refresh token that the backend uses to obtain
# fresh JWTs from WorkOS. The browser holds only the session UUID in
# an HttpOnly cookie — refresh tokens never leave the server.
#
# Not workspace-scoped: a session exists at the user level and
# precedes workspace selection.
class UserSession < ApplicationRecord
  encrypts :refresh_token, deterministic: false

  belongs_to :user

  validates :expires_at, presence: true

  scope :active,  -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  # Marks this session as revoked.
  #
  # @return [Boolean]
  def revoke!
    update!(revoked_at: Time.current)
  end

  # @return [Boolean] true if the session has been revoked
  def revoked?
    revoked_at.present?
  end

  # @return [Boolean] true if the session has not expired and is not revoked
  def active?
    !revoked? && expires_at > Time.current
  end
end

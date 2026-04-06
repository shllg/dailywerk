# frozen_string_literal: true

require "digest"

# Stores compact, durable memories that agents can retrieve across sessions.
class MemoryEntry < ApplicationRecord
  include WorkspaceScoped

  CATEGORIES = %w[
    context
    fact
    instruction
    preference
    profile
    project
    relationship
    rule
  ].freeze
  SOURCES = %w[extraction manual system tool user].freeze
  EMBEDDING_DIMENSIONS = 1536

  has_neighbors :embedding

  belongs_to :agent, optional: true
  belongs_to :session, optional: true
  belongs_to :source_message, class_name: "Message", optional: true

  has_many :versions,
           -> { order(created_at: :desc) },
           class_name: "MemoryEntryVersion",
           dependent: :delete_all,
           inverse_of: :memory_entry

  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :content, presence: true
  validates :importance, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 10 }
  validates :confidence, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validates :fingerprint, presence: true
  validate :agent_matches_workspace
  validate :session_matches_workspace
  validate :source_message_matches_workspace

  before_validation :assign_fingerprint

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :promoted, -> { where(staged: false) }
  scope :staged, -> { where(staged: true) }
  scope :embedded, -> { where.not(embedding: nil) }
  scope :shared, -> { where(agent_id: nil) }

  # @return [Boolean]
  def shared?
    agent_id.nil?
  end

  # @return [String]
  def scope_label
    shared? ? "shared" : "private"
  end

  # @return [String]
  def embedding_source_text
    content.to_s
  end

  # @param category [String]
  # @param content [String]
  # @return [String]
  def self.fingerprint_for(category:, content:)
    normalized_content = content.to_s.downcase.squish
    Digest::SHA256.hexdigest([ category.to_s.downcase, normalized_content ].join("\u0000"))
  end

  private

  # @return [void]
  def assign_fingerprint
    return if content.blank? || category.blank?

    self.fingerprint = self.class.fingerprint_for(category:, content:)
  end

  # @return [void]
  def agent_matches_workspace
    return if agent.blank? || workspace.blank?
    return if agent.workspace_id == workspace_id

    errors.add(:agent, "must belong to the current workspace")
  end

  # @return [void]
  def session_matches_workspace
    return if session.blank? || workspace.blank?
    return if session.workspace_id == workspace_id

    errors.add(:session, "must belong to the current workspace")
  end

  # @return [void]
  def source_message_matches_workspace
    return if source_message.blank? || workspace.blank?
    return if source_message.workspace_id == workspace_id

    errors.add(:source_message, "must belong to the current workspace")
  end
end

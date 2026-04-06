# frozen_string_literal: true

# Rewrites a user's synthesized profile from promoted memories and recent archives.
#
# Unlike compaction (which appends), this service produces a fresh, bounded
# profile every time. The profile is always injected into the agent's system
# prompt so the assistant knows who it is talking to.
class ProfileSynthesisService
  DEFAULT_MODEL = "gpt-4o-mini"
  MAX_PROFILE_TOKENS = 2_000
  ARCHIVE_LOOKBACK = 30.days

  # @param user [User]
  # @param workspace [Workspace]
  def initialize(user:, workspace:)
    @user = user
    @workspace = workspace
  end

  # Synthesizes a fresh profile and persists it.
  #
  # @return [UserProfile]
  def call
    memories = load_memories
    archives = load_archives
    return skip_synthesis if memories.empty? && archives.empty?

    profile_record = find_or_initialize_profile
    new_profile = generate_profile(
      memories:,
      archives:,
      current_profile: profile_record.synthesized_profile
    )

    profile_record.update!(
      synthesized_profile: new_profile,
      profile_synthesized_at: Time.current
    )
    profile_record
  end

  private

  # @return [Array<MemoryEntry>]
  def load_memories
    @workspace.memory_entries
              .where(active: true, staged: false)
              .order(importance: :desc, updated_at: :desc)
              .limit(50)
              .to_a
  rescue ActiveRecord::StatementInvalid
    # staged column may not exist yet during migration rollout
    @workspace.memory_entries
              .where(active: true)
              .order(importance: :desc, updated_at: :desc)
              .limit(50)
              .to_a
  end

  # @return [Array<ConversationArchive>]
  def load_archives
    @workspace.conversation_archives
              .where("ended_at > ?", ARCHIVE_LOOKBACK.ago)
              .order(ended_at: :desc)
              .limit(10)
              .to_a
  end

  # @return [UserProfile]
  def find_or_initialize_profile
    UserProfile.find_or_initialize_by(user: @user, workspace: @workspace)
  end

  # @param memories [Array<MemoryEntry>]
  # @param archives [Array<ConversationArchive>]
  # @param current_profile [String, nil]
  # @return [String]
  def generate_profile(memories:, archives:, current_profile:)
    memory_text = memories.map { |m| "- [#{m.category}] #{m.content}" }.join("\n")
    archive_text = archives.map { |a| "- #{a.summary&.first(300)}" }.join("\n")

    prior = current_profile.present? ? "\nCurrent profile (refine, do not start from scratch):\n#{current_profile}\n" : ""

    response = RubyLLM.chat(model: DEFAULT_MODEL)
                      .with_temperature(0.1)
                      .ask(<<~PROMPT)
                        Write a concise user profile (max #{MAX_PROFILE_TOKENS} tokens) from the evidence below.
                        This profile will be injected into every conversation so the assistant knows who it is talking to.

                        Structure with these sections (skip empty ones):
                        - **Work style**: how the user prefers to work, tools, environment
                        - **Preferences**: recurring likes, dislikes, communication style
                        - **Active projects**: what the user is currently working on
                        - **People & relationships**: colleagues, teams, collaborators mentioned
                        - **Constraints & rules**: standing instructions, things to avoid
                        - **Open loops**: unresolved questions, deferred decisions

                        Be factual and specific. Use the user's own words where possible.
                        Do not speculate. If evidence is thin, keep the section short.
                        #{prior}
                        Memories:
                        #{memory_text}

                        Recent conversation summaries:
                        #{archive_text}
                      PROMPT

    response.content.to_s.strip
  end

  # @return [UserProfile, nil]
  def skip_synthesis
    Rails.logger.info("[ProfileSynthesis] No memories or archives for user #{@user.id} in workspace #{@workspace.id}, skipping")
    nil
  end
end

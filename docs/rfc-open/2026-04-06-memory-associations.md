---
type: rfc
title: Memory Associations Graph
domain: agents
created: 2026-04-06
status: open
depends_on:
  - prd/03-agentic-system
prerequisite: Memory consolidation pipeline (staged promotion, MemoryConsolidationService) — shipped 2026-04-06
---

# RFC: Memory Associations Graph

> Connect related memories so retrieval returns clusters of knowledge, not isolated facts.

## 1. Problem

Today, each `memory_entry` is an atom. The agent recalls individual facts via semantic search, but has no way to follow connections between them. When the user says "tell me about my billing project," the agent retrieves the top-N facts independently — it might get "user prefers Stripe" and "billing migration deadline is Q3" but miss "Alex owns the billing backend" because that memory's embedding is slightly less similar.

In Karpathy's wiki pattern, knowledge compounds through links. A wiki page about "billing project" links to pages about Stripe, Alex, and the Q3 deadline. We need the same for memories: when one memory is recalled, its neighbors should come along.

## 2. Design

### 2.1 Join Table: `memory_entry_associations`

```
memory_entry_associations (
  id          uuid PK (UUIDv7)
  source_id   uuid NOT NULL FK → memory_entries
  target_id   uuid NOT NULL FK → memory_entries
  relationship_type  text NOT NULL
  confidence  decimal(3,2) DEFAULT 0.8
  created_at  timestamp NOT NULL
)

UNIQUE INDEX (source_id, target_id)
INDEX (target_id)   -- for reverse lookups
```

**Relationship types:**

| Type | Meaning | Example |
|------|---------|---------|
| `supports` | Target reinforces source | "User prefers dark mode" ← "User set VS Code theme to One Dark" |
| `contradicts` | Target conflicts with source | "User prefers tabs" ↔ "User switched to spaces last week" |
| `supersedes` | Target replaces source (newer) | "Project deadline is Q2" → "Project deadline moved to Q3" |
| `elaborates` | Target adds detail to source | "User works at Acme" ← "User is CTO at Acme since 2024" |
| `relates` | General topical connection | "Billing project" ↔ "Stripe integration" |

Associations are **directional** (source → target) but retrieval traverses both directions. The `contradicts` type is always bidirectional (create two rows).

### 2.2 WorkspaceScoped + RLS

The join table does NOT have its own `workspace_id` — it inherits workspace scope from the parent `memory_entries` via `enable_parent_rls!(:memory_entry_associations, parent_table: :memory_entries, parent_fk: :source_id)`.

### 2.3 Model

```ruby
class MemoryEntryAssociation < ApplicationRecord
  RELATIONSHIP_TYPES = %w[supports contradicts supersedes elaborates relates].freeze

  belongs_to :source, class_name: "MemoryEntry"
  belongs_to :target, class_name: "MemoryEntry"

  validates :relationship_type, inclusion: { in: RELATIONSHIP_TYPES }
  validates :source_id, uniqueness: { scope: :target_id }
  validate :no_self_reference
end
```

Add to `MemoryEntry`:
```ruby
has_many :outgoing_associations, class_name: "MemoryEntryAssociation",
         foreign_key: :source_id, dependent: :delete_all
has_many :incoming_associations, class_name: "MemoryEntryAssociation",
         foreign_key: :target_id, dependent: :delete_all
has_many :associated_memories, through: :outgoing_associations, source: :target
has_many :reverse_associated_memories, through: :incoming_associations, source: :source
```

## 3. Association Creation

Associations are created in two places:

### 3.1 During Memory Consolidation (nightly)

`MemoryConsolidationService` already does semantic similarity checks for deduplication. Extend the evaluation step:

- When a candidate is **promoted** and has similar promoted memories (distance 0.15–0.5), create a `relates` association
- When a candidate **supersedes** an older memory, create a `supersedes` association (already tracked but not persisted as a link)
- When two memories in the same category have very different content but overlap topically (distance 0.2–0.4), use an LLM call to classify the relationship type

### 3.2 During Memory Extraction (per-response)

After `MemoryExtractionJob` stores new memories, check the top-3 semantically similar existing promoted memories. If distance < 0.4, create a `relates` association. This is cheap (reuses the existing embedding) and captures connections while context is fresh.

### 3.3 Periodic Linting (weekly, new job)

`MemoryLintingJob` — a weekly job that:
1. Finds promoted memories with zero associations ("orphans") and attempts to link them
2. Detects `contradicts` pairs where both are still active — flag for consolidation
3. Identifies clusters (connected components) and checks if any cluster should be merged into a single higher-level memory
4. Reports stats to logs

## 4. Cluster-Aware Retrieval

### 4.1 1-Hop Graph Traversal

When `MemoryRetrievalService` selects top-N memories, also fetch their 1-hop neighbors:

```ruby
def select_memories
  primary = rank_candidates(scope, query).first(12)
  neighbor_ids = MemoryEntryAssociation
    .where(source_id: primary.map(&:id))
    .or(MemoryEntryAssociation.where(target_id: primary.map(&:id)))
    .pluck(:source_id, :target_id)
    .flatten
    .uniq - primary.map(&:id)
  
  neighbors = scope.where(id: neighbor_ids).to_a
  
  # Interleave: primary memories first, then neighbors, all within budget
  keep_with_budget(primary + neighbors, budget) { |e| estimate_tokens(e.content) }
end
```

### 4.2 Token Budget

Neighbors share the existing 10% memory budget. They don't get additional budget — they compete with primary results. This ensures the feature is cost-neutral and only displaces lower-ranked isolated memories.

### 4.3 Deduplication

A memory can appear as both a primary hit and a neighbor. Deduplicate by ID before budget calculation.

## 5. Migration

```ruby
class CreateMemoryEntryAssociations < ActiveRecord::Migration[8.1]
  include RlsMigrationHelpers

  def up
    create_table :memory_entry_associations, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :source, type: :uuid, null: false, foreign_key: { to_table: :memory_entries }
      t.references :target, type: :uuid, null: false, foreign_key: { to_table: :memory_entries }
      t.text :relationship_type, null: false
      t.decimal :confidence, precision: 3, scale: 2, default: 0.8
      t.datetime :created_at, null: false
      t.index %i[source_id target_id], unique: true
    end

    safety_assured do
      enable_parent_rls!(:memory_entry_associations, parent_table: :memory_entries, parent_fk: :source_id)
    end
  end

  def down
    safety_assured { disable_parent_rls!(:memory_entry_associations) }
    drop_table :memory_entry_associations
  end
end
```

## 6. Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Graph grows unbounded | Cap at 10 associations per memory. Linting job prunes weak (low-confidence) links. |
| LLM calls for relationship classification add cost | Only classify during nightly consolidation (bounded by workspace count). Extraction-time associations use distance thresholds only (no LLM). |
| 1-hop traversal adds query latency | Single JOIN query, cached by PostgreSQL. Benchmark against current retrieval. |
| Contradictions persist indefinitely | Linting job flags active contradictions for consolidation review. |
| Parent RLS on join table via source_id only | A memory could be associated with a memory from another workspace if cross-workspace entries existed. Prevented by MemoryEntry's WorkspaceScoped concern — cross-workspace entries cannot exist. |

## 7. Scope Boundaries

**In scope:**
- Join table + model + migration + RLS
- Association creation during consolidation and extraction
- 1-hop retrieval in MemoryRetrievalService
- Weekly linting job

**Out of scope (future):**
- UI for viewing/editing associations
- Multi-hop traversal (2+ hops)
- Weighted edges (beyond confidence score)
- Automatic cluster summarization (merging a cluster into one memory)
- Vault-to-memory associations (linking vault documents to structured memories)

## 8. Prerequisites

- Staged memory promotion pipeline must be stable (shipped 2026-04-06)
- Consolidation service running nightly without errors for >= 1 week
- Sufficient memory volume per workspace to validate association quality (>50 promoted memories)

## 9. Verification

- Create 20+ memories across 3-4 topics → consolidation creates associations → retrieval returns clusters
- Query about topic A → get primary memories + related topic-A neighbors within budget
- Contradicting memories → linting flags them, consolidation resolves on next pass
- Isolated memory → linting attempts to link, creates association if semantically close
- Performance: retrieval with 1-hop traversal adds < 5ms over current baseline

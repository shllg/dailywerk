# Prompt Injection Security Review (Codex)

## Purpose

Review DailyWerk's agentic system for prompt injection vulnerabilities — places where user-controlled content reaches LLM system prompts or tool execution contexts.

## Injection Surfaces to Audit

1. **Agent config → system prompt**: `instructions`, `soul`, `identity` fields flow through `PromptBuilder` into the LLM system prompt. User-editable via API and dashboard.
2. **Vault content → agent context**: Vault files, memory entries, and conversation archives injected during `MemoryRetrievalService.build_context`.
3. **Inbound messages**: Chat, email forwarding, bridge channels — adversarial instructions embedded in user messages.
4. **Tool arguments**: User-controlled input in tool `execute` method parameters.
5. **MCP tool results**: External MCP server responses injected into agent context.

## For Each Surface, Check

- Is user content in system prompt or user message block? (System prompt = higher risk)
- Are there framing delimiters limiting user-provided text authority?
- Can injected content override safety rules or tool access controls?
- Can it trigger data exfiltration (vault, memories, credentials)?
- Can it trigger unauthorized tool calls (email send, file write, admin tools)?
- Is there output filtering for exfiltration patterns?
- Do tools enforce their own access controls independently?

## Key Files

- `app/services/prompt_builder.rb` — assembles system prompt
- `app/services/agent_runtime.rb` — core agent loop
- `app/services/context_builder.rb` — builds LLM context
- `app/models/agent.rb` — agent configuration
- `app/tools/**/*.rb` — all tool implementations
- `app/controllers/api/v1/agents_controller.rb` — agent config API

## Reference

- docs/prd/03-agentic-system.md §2 (Agent Configuration Security)
- OWASP LLM Top 10: LLM01 (Prompt Injection)

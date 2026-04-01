# Prompt Injection Security Review

Review the current codebase for prompt injection vulnerabilities in the agentic system.

## Scope

Analyze all code paths where user-controlled content reaches LLM system prompts or tool execution:

1. **Agent configuration fields**: `instructions`, `soul`, `identity` — user-editable text injected into system prompts via `PromptBuilder`
2. **Vault content in context**: Files from user vaults injected as context during memory retrieval or tool execution
3. **Inbound messages**: User messages from chat, email forwarding, bridge channels — could contain adversarial instructions
4. **Tool arguments**: User-controlled input passed to tool `execute` methods — could manipulate tool behavior
5. **MCP tool results**: External MCP server responses injected into agent context — untrusted third-party data

## Checklist

For each injection surface found, evaluate:

- [ ] Is user content placed in the system prompt or a user message block?
- [ ] Are there delimiter/framing instructions that limit the authority of user-provided text?
- [ ] Can the injected content override safety rules, tool access controls, or workspace isolation?
- [ ] Can the injected content cause data exfiltration (vault contents, memories, credentials)?
- [ ] Can the injected content trigger unauthorized tool calls (email send, file write, admin tools)?
- [ ] Is there output filtering to detect exfiltration patterns?
- [ ] Are tool-level access controls enforced independently of the system prompt?

## Output

For each finding, report:
- **Surface**: Where user content enters the LLM context
- **Risk**: What an attacker could achieve
- **Severity**: Critical / High / Medium / Low
- **Mitigation**: Recommended fix (structured config, sandboxing, output filtering, tool-level auth)

## Files to Check

```
app/services/prompt_builder.rb
app/services/agent_runtime.rb
app/services/context_builder.rb
app/services/memory_retrieval_service.rb
app/services/simple_chat_service.rb
app/models/agent.rb
app/tools/**/*.rb
app/controllers/api/v1/agents_controller.rb
app/jobs/chat_stream_job.rb
app/jobs/memory_extraction_job.rb
```

## Reference

- docs/prd/03-agentic-system.md §2 (Agent Configuration Security)
- OWASP LLM Top 10: LLM01 (Prompt Injection)

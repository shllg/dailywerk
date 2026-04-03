---
name: llm-integration-testing
description: Write and run opt-in live LLM integration tests without polluting the default suite.
---

# LLM Integration Testing Skill

Use this only when a change genuinely needs live provider coverage.

## Rules

- Default Ruby coverage lives in `bin/test` and must stay hermetic.
- Live provider tests live in `test/llm_integration/` and run through `bin/test-llm`.
- Gate every live test with `RUN_LIVE_LLM_TESTS=1` and the provider key it needs.
- Keep the request tiny and the assertions structural.
- Prefer one smoke test per provider/path over many overlapping live tests.
- Do not use live LLM tests inflationarily.

## Pattern

1. Subclass `LlmIntegrationTestCase`.
2. Call the provider guard such as `require_openai_api_key!`.
3. Exercise one real app path end-to-end.
4. Assert stable shape-level outcomes, not brittle generated prose.

## When Not To Use It

- Local business logic can be covered with a normal model/service/job test.
- The behavior only needs a stubbed `RubyLLM.embed` or config key to stay hermetic.
- The test would add cost or latency without covering new provider integration risk.

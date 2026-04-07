import { describe, expect, it } from 'vitest'
import {
  buildResetConfirmation,
  buildUpdatePayload,
  formStateFromAgent,
} from './AgentConfigPanel.utils'
import type { AgentConfig, AgentDefaults } from '../../types/agent'

const agent: AgentConfig = {
  id: 'agent-1',
  slug: 'main',
  name: 'DailyWerk',
  model_id: 'gpt-5.4',
  memory_isolation: 'shared',
  provider: null,
  temperature: 0.7,
  instructions: null,
  soul: 'Helpful',
  identity: {
    persona: 'Planner',
    tone: 'Direct',
    constraints: 'No fluff',
  },
  params: {},
  thinking: {
    enabled: true,
    budget_tokens: 2_000,
  },
  tool_names: [],
  is_default: true,
  active: true,
}

const defaults: AgentDefaults = {
  name: 'Factory Agent',
  model_id: 'gpt-5.4-mini',
  memory_isolation: 'shared',
  provider: null,
  temperature: 0.3,
  instructions: null,
  soul: null,
  identity: {},
  params: {},
  thinking: {},
  tool_names: [],
}

describe('AgentConfigPanel utils', () => {
  it('hydrates form state from an agent config', () => {
    expect(formStateFromAgent(agent)).toEqual({
      name: 'DailyWerk',
      model_id: 'gpt-5.4',
      provider: '',
      temperature: '0.7',
      instructions: '',
      soul: 'Helpful',
      identity: {
        persona: 'Planner',
        tone: 'Direct',
        constraints: 'No fluff',
      },
      thinking: {
        enabled: true,
        budget_tokens: '2000',
      },
    })
  })

  it('builds a normalized update payload', () => {
    const payload = buildUpdatePayload({
      name: '  DailyWerk  ',
      model_id: ' gpt-5.4 ',
      provider: ' ',
      temperature: '0.9',
      instructions: ' Be concise ',
      soul: ' ',
      identity: {
        persona: ' Planner ',
        tone: ' ',
        constraints: ' No fluff ',
      },
      thinking: {
        enabled: false,
        budget_tokens: '5000',
      },
    })

    expect(payload).toEqual({
      name: 'DailyWerk',
      model_id: 'gpt-5.4',
      provider: null,
      temperature: 0.9,
      instructions: 'Be concise',
      soul: null,
      identity: {
        persona: 'Planner',
        constraints: 'No fluff',
      },
      thinking: {},
    })
  })

  it('builds a reset confirmation message from defaults', () => {
    expect(buildResetConfirmation(agent, defaults)).toContain('Factory Agent')
    expect(buildResetConfirmation(agent, defaults)).toContain('gpt-5.4-mini')
  })
})

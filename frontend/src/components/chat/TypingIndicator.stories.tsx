import preview from '#.storybook/preview'
import { TypingIndicator } from './TypingIndicator'

const meta = preview.meta({
  title: 'Chat/TypingIndicator',
  component: TypingIndicator,
  parameters: { layout: 'padded' },
  tags: ['autodocs'],
})

export default meta

export const Default = meta.story({})

export const WithAgentName = meta.story({
  args: { agentName: 'DailyWerk' },
})

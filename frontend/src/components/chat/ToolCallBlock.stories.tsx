import preview from '#.storybook/preview'
import { ToolCallBlock } from './ToolCallBlock'

const meta = preview.meta({
  title: 'Chat/ToolCallBlock',
  component: ToolCallBlock,
  parameters: { layout: 'padded' },
  tags: ['autodocs'],
  decorators: [
    (Story) => (
      <div className="max-w-xl">
        <Story />
      </div>
    ),
  ],
})

export default meta

export const Pending = meta.story({
  args: {
    toolCall: {
      id: '1',
      name: 'search_vault',
      args: { query: 'quarterly review' },
      status: 'pending',
    },
  },
})

export const Running = meta.story({
  args: {
    toolCall: {
      id: '2',
      name: 'fetch_calendar',
      args: { date: '2026-03-30' },
      status: 'running',
    },
  },
})

export const Completed = meta.story({
  args: {
    toolCall: {
      id: '3',
      name: 'search_vault',
      args: { query: 'quarterly review' },
      status: 'completed',
      result: 'Found 5 matching notes in your vault.',
    },
  },
})

export const Error = meta.story({
  args: {
    toolCall: {
      id: '4',
      name: 'send_email',
      args: { to: 'team@example.com' },
      status: 'error',
      result: 'Permission denied: email integration not configured.',
    },
  },
})

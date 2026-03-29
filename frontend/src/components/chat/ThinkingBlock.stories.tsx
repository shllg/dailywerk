import preview from '#.storybook/preview'
import { ThinkingBlock } from './ThinkingBlock'

const meta = preview.meta({
  title: 'Chat/ThinkingBlock',
  component: ThinkingBlock,
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

export const Collapsed = meta.story({
  args: {
    content:
      'The user is asking about their calendar. I should check the calendar integration and look for events tomorrow. Let me query the vault for any related notes as well.',
  },
})

export const Streaming = meta.story({
  args: {
    content: 'Let me think about this step by step...',
    isStreaming: true,
  },
})

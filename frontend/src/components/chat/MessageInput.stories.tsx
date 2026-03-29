import preview from '#.storybook/preview'
import { MessageInput } from './MessageInput'

const meta = preview.meta({
  title: 'Chat/MessageInput',
  component: MessageInput,
  parameters: { layout: 'padded' },
  tags: ['autodocs'],
  decorators: [
    (Story) => (
      <div className="max-w-2xl bg-gray-950">
        <Story />
      </div>
    ),
  ],
})

export default meta

export const Default = meta.story({
  args: {
    onSend: (content: string) => console.log('Send:', content),
  },
})

export const Disabled = meta.story({
  args: {
    onSend: (content: string) => console.log('Send:', content),
    disabled: true,
  },
})

export const CustomPlaceholder = meta.story({
  args: {
    onSend: (content: string) => console.log('Send:', content),
    placeholder: 'Ask DailyWerk anything...',
  },
})

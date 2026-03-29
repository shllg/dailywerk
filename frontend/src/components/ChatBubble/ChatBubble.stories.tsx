import preview from '#.storybook/preview'
import { ChatBubble } from './ChatBubble'

const meta = preview.meta({
  title: 'Chat/ChatBubble',
  component: ChatBubble,
  parameters: { layout: 'padded' },
  tags: ['autodocs'],
  argTypes: {
    role: { control: 'select', options: ['user', 'assistant', 'system'] },
    isStreaming: { control: 'boolean' },
  },
})

export default meta

export const UserMessage = meta.story({
  args: {
    role: 'user',
    children: 'Can you look up my calendar for tomorrow?',
    timestamp: '10:32 AM',
  },
})

export const AssistantMessage = meta.story({
  args: {
    role: 'assistant',
    agentName: 'DailyWerk',
    children:
      'You have 3 events tomorrow: standup at 9:00, design review at 11:00, and a dentist appointment at 3:30 PM.',
    timestamp: '10:32 AM',
  },
})

export const AssistantStreaming = meta.story({
  args: {
    role: 'assistant',
    agentName: 'DailyWerk',
    children: 'Looking up your calendar',
    isStreaming: true,
  },
})

export const SystemMessage = meta.story({
  args: {
    role: 'system',
    children: 'Handed off to Research Agent',
  },
})

export const LongMessage = meta.story({
  args: {
    role: 'assistant',
    agentName: 'Research',
    children:
      'Based on my analysis of your vault notes and recent conversations, here are the key findings:\n\n1. The quarterly review is scheduled for April 5th\n2. Three action items remain from last week\n3. Your nutrition tracking shows improved consistency this month',
    timestamp: '10:35 AM',
  },
})

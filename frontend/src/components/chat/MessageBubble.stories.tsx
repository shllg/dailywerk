import preview from '#.storybook/preview'
import { MessageBubble } from './MessageBubble'

const meta = preview.meta({
  title: 'Chat/MessageBubble',
  component: MessageBubble,
  parameters: { layout: 'padded' },
  tags: ['autodocs'],
})

export default meta

export const UserMessage = meta.story({
  args: {
    message: {
      id: '1',
      role: 'user',
      content: 'Can you look up my calendar for tomorrow?',
      timestamp: '10:32 AM',
      status: 'sent',
    },
  },
})

export const AssistantMessage = meta.story({
  args: {
    message: {
      id: '2',
      role: 'assistant',
      content:
        'You have **3 events** tomorrow:\n\n1. Standup at 9:00 AM\n2. Design review at 11:00 AM\n3. Dentist appointment at 3:30 PM\n\nWould you like me to reschedule anything?',
      agentName: 'DailyWerk',
      timestamp: '10:32 AM',
      status: 'sent',
    },
  },
})

export const StreamingMessage = meta.story({
  args: {
    message: {
      id: '3',
      role: 'assistant',
      content: 'Looking through your vault notes for relevant',
      agentName: 'Research',
      timestamp: '10:33 AM',
      status: 'streaming',
    },
  },
})

export const WithToolCall = meta.story({
  args: {
    message: {
      id: '4',
      role: 'assistant',
      content: 'Found 5 matching notes. Here are the highlights...',
      agentName: 'Research',
      timestamp: '10:34 AM',
      status: 'sent',
      toolCalls: [
        {
          id: 'tc-1',
          name: 'search_vault',
          args: { query: 'quarterly review' },
          status: 'completed',
          result: 'Found 5 matching notes.',
        },
      ],
    },
  },
})

export const WithThinking = meta.story({
  args: {
    message: {
      id: '5',
      role: 'assistant',
      content:
        'Based on your notes, the quarterly review is **April 5th** and there are 3 open action items.',
      agentName: 'DailyWerk',
      timestamp: '10:35 AM',
      status: 'sent',
      thinkingContent:
        'The user is asking about the quarterly review. Let me check their vault for related notes and calendar entries. I found entries tagged with #quarterly-review dating from last week.',
    },
  },
})

export const SystemMessage = meta.story({
  args: {
    message: {
      id: '6',
      role: 'system',
      content: 'Handed off to Research Agent',
      timestamp: '10:33 AM',
      status: 'sent',
    },
  },
})

export const ErrorMessage = meta.story({
  args: {
    message: {
      id: '7',
      role: 'assistant',
      content: 'I encountered an error while trying to access your calendar.',
      agentName: 'DailyWerk',
      timestamp: '10:36 AM',
      status: 'error',
    },
  },
})

import preview from '#.storybook/preview'
import { ConversationList } from './ConversationList'

const meta = preview.meta({
  title: 'Chat/ConversationList',
  component: ConversationList,
  parameters: { layout: 'fullscreen' },
  tags: ['autodocs'],
  decorators: [
    (Story) => (
      <div className="w-72 h-[600px]">
        <Story />
      </div>
    ),
  ],
})

export default meta

const mockSessions = [
  {
    id: '1',
    title: 'Calendar review',
    lastMessage: 'You have 3 events tomorrow...',
    lastMessageAt: '10:32 AM',
    agentName: 'DailyWerk',
    messageCount: 8,
  },
  {
    id: '2',
    title: 'Quarterly report analysis',
    lastMessage: 'Based on your vault notes...',
    lastMessageAt: 'Yesterday',
    agentName: 'Research',
    messageCount: 15,
  },
  {
    id: '3',
    title: 'Email drafts',
    lastMessage: "Here's a draft for the team update...",
    lastMessageAt: 'Mar 27',
    agentName: 'Writer',
    messageCount: 4,
  },
  {
    id: '4',
    title: 'Nutrition tracking',
    lastMessage: 'Your weekly summary shows improved...',
    lastMessageAt: 'Mar 25',
    agentName: 'DailyWerk',
    messageCount: 22,
  },
]

export const Default = meta.story({
  args: {
    sessions: mockSessions,
    activeSessionId: '1',
    onSelectSession: (id: string) => console.log('Select:', id),
    onNewSession: () => console.log('New session'),
  },
})

export const Empty = meta.story({
  args: {
    sessions: [],
    onSelectSession: (id: string) => console.log('Select:', id),
    onNewSession: () => console.log('New session'),
  },
})

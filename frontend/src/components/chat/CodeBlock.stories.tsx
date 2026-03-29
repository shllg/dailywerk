import preview from '#.storybook/preview'
import { CodeBlock } from './CodeBlock'

const meta = preview.meta({
  title: 'Chat/CodeBlock',
  component: CodeBlock,
  parameters: { layout: 'padded' },
  tags: ['autodocs'],
})

export default meta

export const TypeScript = meta.story({
  args: {
    language: 'typescript',
    code: `interface User {
  id: string
  name: string
  email: string
}

function greet(user: User): string {
  return \`Hello, \${user.name}!\`
}`,
  },
})

export const Ruby = meta.story({
  args: {
    language: 'ruby',
    code: `class ChatService
  def initialize(user:)
    @user = user
  end

  def call(message)
    session = @user.chat_sessions.find_or_create_current
    session.messages.create!(role: :user, content: message)
  end
end`,
  },
})

export const Bash = meta.story({
  args: {
    language: 'bash',
    code: `docker compose up -d
bin/rails db:migrate
cd frontend && pnpm dev`,
  },
})

export const PlainText = meta.story({
  args: {
    code: 'No language specified, renders as plain text.',
  },
})

import preview from '#.storybook/preview'
import { MarkdownRenderer } from './MarkdownRenderer'

const meta = preview.meta({
  title: 'Chat/MarkdownRenderer',
  component: MarkdownRenderer,
  parameters: { layout: 'padded' },
  tags: ['autodocs'],
  decorators: [
    (Story) => (
      <div className="bg-gray-800 rounded-2xl p-4 text-gray-100 text-sm leading-relaxed max-w-xl">
        <Story />
      </div>
    ),
  ],
})

export default meta

export const BasicMarkdown = meta.story({
  args: {
    content: `Here's a summary of your tasks:

- **Design review** is scheduled for tomorrow at 11 AM
- The *quarterly report* needs your sign-off
- Don't forget to check the [shared doc](https://example.com)

> The team is making great progress this sprint.`,
  },
})

export const WithCodeBlock = meta.story({
  args: {
    content: `Here's how to set up the dev environment:

\`\`\`bash
docker compose up -d
bin/rails db:migrate
cd frontend && pnpm dev
\`\`\`

You can also run \`bin/dev\` to start everything at once.`,
  },
})

export const WithTable = meta.story({
  args: {
    content: `| Agent | Status | Last Active |
|-------|--------|-------------|
| Research | Active | 2 min ago |
| Calendar | Idle | 15 min ago |
| Email | Active | Just now |`,
  },
})

export const ComplexMessage = meta.story({
  args: {
    content: `## Analysis Complete

I found **3 key insights** from your vault:

1. Your meeting frequency increased by 40% this quarter
2. Most productive hours are between 9-11 AM
3. The \`project-alpha\` tag appears in 23 notes

### Code Example

\`\`\`typescript
const insights = await analyzeVault({
  timeRange: 'last-quarter',
  focus: ['meetings', 'productivity'],
})
\`\`\`

---

*Based on 147 vault entries analyzed.*`,
  },
})

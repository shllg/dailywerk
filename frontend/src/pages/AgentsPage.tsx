import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function AgentsPage() {
  return (
    <PlaceholderPage
      eyebrow="Agent workspace"
      title="Agent roster and routing"
      description="The first production slice still exposes one default agent. This screen reserves the structure for specialist agents, handoff targets, and channel-to-agent bindings without faking backend CRUD that does not exist yet."
      footer="The sidebar already shows the live default agent. This page becomes the real management surface once the multi-agent API lands."
      highlights={[
        'Default agent visibility',
        'Future specialist handoffs',
        'Workspace-scoped agent management',
      ]}
      panels={[
        {
          title: 'Main agent',
          description:
            'The current workspace default agent remains the primary chat surface and keeps the existing settings drawer intact.',
        },
        {
          title: 'Specialists later',
          description:
            'Research, diary, or health agents will fit here once create/delete and routing APIs exist.',
        },
        {
          title: 'Channel bindings',
          description:
            'The PRD already reserves per-channel routing. This page leaves room for that instead of forcing another redesign later.',
        },
      ]}
    />
  )
}

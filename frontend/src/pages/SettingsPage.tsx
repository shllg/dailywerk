import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function SettingsPage() {
  return (
    <PlaceholderPage
      eyebrow="Application settings"
      title="System settings and UX preferences"
      description="The active agent is already configurable through the drawer. This page stays focused on broader settings that should outlive any single chat session: appearance, developer tools, and workspace-wide defaults."
      footer="That separation keeps agent behavior in the drawer and keeps general system settings discoverable as the product grows."
      highlights={[
        'Appearance and UX',
        'Developer mode later',
        'Workspace-wide defaults',
      ]}
      panels={[
        {
          title: 'General preferences',
          description:
            'Theme, density, notification posture, and other UX-level settings belong here instead of in the agent config.',
        },
        {
          title: 'Debug surfaces',
          description:
            'The debug-tools RFC already expects additional routes and a developer toggle; this page is the stable entry point.',
        },
        {
          title: 'Settings hub',
          description:
            'As more configuration surfaces appear, this page can act as a directory rather than forcing users through nested drawers.',
        },
      ]}
    />
  )
}

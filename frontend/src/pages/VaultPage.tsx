import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function VaultPage() {
  return (
    <PlaceholderPage
      eyebrow="Knowledge surface"
      title="Vault guides, sync, and browsing"
      description="The vault becomes a first-class UI area once guide editing, sync configuration, and file browsing land. This placeholder anchors those flows in the navigation now so the app shell matches the future information architecture."
      footer="The first likely UI slice here is the vault guide editor, because the RFC already defines a dashboard route for it."
      highlights={[
        'Vault guide editing',
        'Obsidian sync configuration',
        'Future file browser',
      ]}
      panels={[
        {
          title: 'Guide-first editing',
          description:
            'Users need a clear place to shape how agents organize files before a full vault browser exists.',
        },
        {
          title: 'Sync posture',
          description:
            'Obsidian connectivity, health, and vault-specific settings belong next to the guide instead of being buried in generic settings.',
        },
        {
          title: 'Room for growth',
          description:
            'Snapshots, versions, and browse/search surfaces can expand here without changing the top-level navigation again.',
        },
      ]}
    />
  )
}

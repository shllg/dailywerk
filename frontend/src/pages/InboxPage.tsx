import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function InboxPage() {
  return (
    <PlaceholderPage
      eyebrow="Email operations"
      title="Inbound email and mailbox access"
      description="Email shows up in multiple forms in the roadmap: zero-setup inbound forwarding, IMAP/SMTP credentials, and BYOA Gmail access. Grouping them under an Inbox surface keeps the mental model clean for users."
      footer="Inbound forwarding is the simplest planned slice, so this page can start by showing the workspace address and allowlist before it grows into full mailbox tooling."
      highlights={[
        'Inbound forwarding',
        'IMAP and SMTP credentials',
        'Gmail BYOA later',
      ]}
      panels={[
        {
          title: 'Inbound forwarding',
          description:
            'Each workspace gets a forward-to address plus sender allowlist controls and token rotation.',
        },
        {
          title: 'Active mailbox tools',
          description:
            'IMAP and SMTP integrations live here once the agent can read inboxes and send mail as the user.',
        },
        {
          title: 'Provider-aware setup',
          description:
            'Gmail BYOA and future managed Gmail should feel like variants of the same workflow, not separate products.',
        },
      ]}
    />
  )
}

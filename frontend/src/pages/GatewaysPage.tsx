import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function GatewaysPage() {
  return (
    <PlaceholderPage
      eyebrow="Channels and bridges"
      title="Messaging gateways"
      description="DailyWerk is planned as a chat-first system across web, Telegram, Signal, email, and later WhatsApp. This placeholder gives those integrations a stable navigation home before the implementation slices arrive."
      footer="Gateways are distinct from general integrations: this area is about transport, identity linking, bridge health, and channel-specific rules."
      highlights={[
        'Web chat is live',
        'Telegram and Signal planned',
        'Bridge health and setup',
      ]}
      panels={[
        {
          title: 'Web',
          description:
            'The in-app chat is the default built-in channel and remains the primary landing surface after login.',
        },
        {
          title: 'Bridge-backed channels',
          description:
            'Telegram, Signal, and later WhatsApp need setup, health status, and routing controls that belong together here.',
        },
        {
          title: 'Provisioning UX',
          description:
            'The PRDs call out dedicated guidance for Signal bridge setup and future managed bridge workflows.',
        },
      ]}
    />
  )
}

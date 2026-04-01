import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function IntegrationsPage() {
  return (
    <PlaceholderPage
      eyebrow="Connected systems"
      title="Providers, MCP, and workspace integrations"
      description="Some configuration is not channel-specific: BYOK provider credentials, MCP servers, Google connectivity, and future service-level integrations need a neutral home outside the gateway flow."
      footer="This page will be the shared control plane for external capabilities that shape what an agent can do, not how users talk to it."
      highlights={[
        'BYOK credentials',
        'MCP server management',
        'Google and service connections',
      ]}
      panels={[
        {
          title: 'LLM providers',
          description:
            'OpenAI, Anthropic, OpenRouter, and other provider credentials are workspace-level capability choices.',
        },
        {
          title: 'MCP servers',
          description:
            'User-configurable MCP endpoints need activation state, authorization context, and security review indicators.',
        },
        {
          title: 'Service connectors',
          description:
            'Calendar, Gmail, and future app integrations should reuse one connection model instead of scattering across the UI.',
        },
      ]}
    />
  )
}

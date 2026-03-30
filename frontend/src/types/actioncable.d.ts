declare module '@rails/actioncable' {
  interface Subscription {
    identifier: string
    perform(action: string, data?: Record<string, unknown>): void
    unsubscribe(): void
  }

  interface Subscriptions {
    subscriptions: Subscription[]
    create(
      channel: string | Record<string, unknown>,
      callbacks: {
        connected?(): void
        disconnected?(): void
        received(data: unknown): void
        rejected?(): void
      },
    ): Subscription
  }

  interface Consumer {
    disconnect(): void
    subscriptions: Subscriptions
  }

  export function createConsumer(url?: string): Consumer
}

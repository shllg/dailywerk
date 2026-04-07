import { useEffect } from 'react'
import { getWebsocketTicket } from '../services/authApi'
import { createAuthenticatedConsumer } from '../services/cable'
import type { CableEvent } from './useStreamingState'

interface UseCableSubscriptionParams {
  sessionId: string | null
  token: string | null
  onDisconnected: () => void
  onReceived: (event: CableEvent) => void
  onTicketError: () => void
}

export function useCableSubscription({
  sessionId,
  token,
  onDisconnected,
  onReceived,
  onTicketError,
}: UseCableSubscriptionParams): void {
  useEffect(() => {
    if (!sessionId || !token) return

    let cancelled = false
    let consumer: ReturnType<typeof createAuthenticatedConsumer> | null = null

    void getWebsocketTicket(token)
      .then(({ ticket }) => {
        if (cancelled) return

        consumer = createAuthenticatedConsumer(ticket)

        consumer.subscriptions.create(
          { channel: 'SessionChannel', session_id: sessionId },
          {
            disconnected() {
              onDisconnected()
            },
            received(event: CableEvent) {
              onReceived(event)
            },
          },
        )
      })
      .catch(() => {
        if (cancelled) return

        onTicketError()
      })

    return () => {
      cancelled = true
      consumer?.disconnect()
    }
  }, [onDisconnected, onReceived, onTicketError, sessionId, token])
}

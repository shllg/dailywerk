import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router'
import { useAuth } from '../hooks/useAuth'
import { getMe } from '../services/authApi'

export function AuthCallbackPage() {
  const navigate = useNavigate()
  const { setSession } = useAuth()
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    void getMe()
      .then((response) => {
        if (cancelled) return
        setSession(response.access_token, response.user, response.workspace)
        navigate('/chat', { replace: true })
      })
      .catch(() => {
        if (cancelled) return
        setError('Authentication failed')
        navigate('/login?error=callback_failed', { replace: true })
      })

    return () => {
      cancelled = true
    }
  }, [navigate, setSession])

  if (error) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-gray-950 text-gray-400">
        <p>{error}</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gray-950 text-gray-400">
      <p>Completing sign-in...</p>
    </div>
  )
}

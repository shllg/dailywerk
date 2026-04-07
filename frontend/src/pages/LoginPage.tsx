import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router'
import { useAuth } from '../hooks/useAuth'
import { getAuthProvider } from '../services/authApi'

type HealthResponse = {
  build_sha?: string | null
}

type AuthMode = 'loading' | 'workos' | 'dev'

function formatBuildLabel(payload: HealthResponse | null) {
  if (!payload) return 'Build info unavailable'

  const sha = payload.build_sha?.trim()

  if (!sha) return 'Build info unavailable'

  return `Build ${sha.slice(0, 7)}`
}

export function LoginPage() {
  const { login } = useAuth()
  const [searchParams] = useSearchParams()
  const [email, setEmail] = useState('sascha@dailywerk.com')
  const [error, setError] = useState<string | null>(
    searchParams.get('error'),
  )
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [buildLabel, setBuildLabel] = useState('Loading build info...')
  const [authMode, setAuthMode] = useState<AuthMode>('loading')

  useEffect(() => {
    let isActive = true

    void getAuthProvider()
      .then((cfg) => {
        if (!isActive) return
        setAuthMode(cfg.provider)
      })
      .catch(() => {
        if (!isActive) return
        setAuthMode('dev')
      })

    void fetch('/api/v1/health')
      .then(async (response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return (await response.json()) as HealthResponse
      })
      .then((payload) => {
        if (!isActive) return
        setBuildLabel(formatBuildLabel(payload))
      })
      .catch(() => {
        if (!isActive) return
        setBuildLabel(formatBuildLabel(null))
      })

    return () => {
      isActive = false
    }
  }, [])

  async function handleDevSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)
    setIsSubmitting(true)

    try {
      await login(email)
    } catch (submissionError) {
      const message =
        submissionError instanceof Error
          ? submissionError.message
          : 'Unable to create a session'
      setError(message)
    } finally {
      setIsSubmitting(false)
    }
  }

  async function handleWorkosLogin() {
    setError(null)
    setIsSubmitting(true)

    try {
      await login()
    } catch (submissionError) {
      const message =
        submissionError instanceof Error
          ? submissionError.message
          : 'Unable to start authentication'
      setError(message)
      setIsSubmitting(false)
    }
  }

  return (
    <div className="min-h-screen bg-gray-950 text-gray-100">
      <div className="mx-auto flex min-h-screen max-w-5xl items-center px-6 py-12">
        <div className="grid w-full gap-8 lg:grid-cols-[1.2fr_0.8fr]">
          <section className="rounded-[2rem] border border-gray-800 bg-gradient-to-br from-gray-900 via-gray-950 to-black p-8 shadow-2xl shadow-black/30">
            <p className="mb-4 text-sm uppercase tracking-[0.35em] text-emerald-400/80">
              DailyWerk
            </p>
            <h1 className="max-w-xl text-4xl font-semibold leading-tight text-white">
              {authMode === 'dev'
                ? 'Development sign-in for the workspace and session foundation.'
                : 'Sign in to your workspace.'}
            </h1>
            <p className="mt-4 max-w-lg text-base leading-7 text-gray-400">
              {authMode === 'dev'
                ? 'This temporary screen exists only until WorkOS is wired in. It issues a signed dev token for the seeded local user.'
                : 'Secure authentication powered by WorkOS. Supports SSO, social login, and magic links.'}
            </p>
            <div className="mt-8 flex flex-wrap gap-3 text-sm text-gray-300">
              {authMode === 'dev' ? (
                <>
                  <span className="rounded-full border border-gray-700 bg-gray-900/70 px-4 py-2">
                    Fake session
                  </span>
                  <span className="rounded-full border border-gray-700 bg-gray-900/70 px-4 py-2">
                    Workspace-aware token
                  </span>
                  <span className="rounded-full border border-gray-700 bg-gray-900/70 px-4 py-2">
                    Dev only
                  </span>
                </>
              ) : (
                <>
                  <span className="rounded-full border border-gray-700 bg-gray-900/70 px-4 py-2">
                    SSO ready
                  </span>
                  <span className="rounded-full border border-gray-700 bg-gray-900/70 px-4 py-2">
                    Secure sessions
                  </span>
                  <span className="rounded-full border border-gray-700 bg-gray-900/70 px-4 py-2">
                    Multi-workspace
                  </span>
                </>
              )}
            </div>
          </section>

          <section className="rounded-[2rem] border border-gray-800 bg-gray-900/90 p-8 shadow-xl shadow-black/20">
            {authMode === 'loading' ? (
              <div className="flex items-center justify-center py-12">
                <p className="text-gray-500">Loading...</p>
              </div>
            ) : authMode === 'dev' ? (
              <form className="space-y-5" onSubmit={handleDevSubmit}>
                <div>
                  <label className="mb-2 block text-sm font-medium text-gray-300">
                    Email
                  </label>
                  <input
                    type="email"
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                    className="input input-bordered w-full border-gray-700 bg-gray-950 text-gray-100"
                    placeholder="sascha@dailywerk.com"
                    autoComplete="email"
                  />
                </div>

                {error && (
                  <div className="rounded-2xl border border-red-800 bg-red-950/60 px-4 py-3 text-sm text-red-200">
                    {error}
                  </div>
                )}

                <button
                  type="submit"
                  className="btn w-full border-0 bg-emerald-500 text-gray-950 hover:bg-emerald-400"
                  disabled={isSubmitting}
                >
                  {isSubmitting ? 'Signing In...' : 'Sign In (Dev)'}
                </button>

                <p className="text-center text-xs uppercase tracking-[0.2em] text-gray-500">
                  {buildLabel}
                </p>
              </form>
            ) : (
              <div className="space-y-5">
                {error && (
                  <div className="rounded-2xl border border-red-800 bg-red-950/60 px-4 py-3 text-sm text-red-200">
                    {error}
                  </div>
                )}

                <button
                  type="button"
                  className="btn w-full border-0 bg-emerald-500 text-gray-950 hover:bg-emerald-400"
                  disabled={isSubmitting}
                  onClick={handleWorkosLogin}
                >
                  {isSubmitting ? 'Redirecting...' : 'Sign In'}
                </button>

                <p className="text-center text-xs uppercase tracking-[0.2em] text-gray-500">
                  {buildLabel}
                </p>
              </div>
            )}
          </section>
        </div>
      </div>
    </div>
  )
}

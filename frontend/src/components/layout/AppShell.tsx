import { ChatContainer } from '../chat/ChatContainer'
import { useAuth } from '../../hooks/useAuth'

export function AppShell() {
  const { logout, token, user, workspace } = useAuth()

  if (!token) {
    return null
  }

  return (
    <div className="min-h-screen bg-[radial-gradient(circle_at_top,_rgba(59,130,246,0.18),_transparent_35%),linear-gradient(180deg,_#07111f_0%,_#030712_48%,_#02030a_100%)] text-white">
      <div className="mx-auto flex min-h-screen max-w-7xl flex-col px-4 pb-6 pt-4 sm:px-6 lg:px-8">
        <header className="mb-6 rounded-[28px] border border-white/10 bg-white/5 px-5 py-4 backdrop-blur-xl">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="flex items-center gap-3">
                <div className="rounded-full border border-blue-400/30 bg-blue-500/15 px-3 py-1 text-xs font-semibold uppercase tracking-[0.24em] text-blue-200">
                  DailyWerk
                </div>
                <span className="text-xs uppercase tracking-[0.24em] text-slate-400">
                  Web Chat
                </span>
              </div>
              <h1 className="mt-3 text-3xl font-semibold tracking-tight text-slate-50">
                {workspace?.name}
              </h1>
              <p className="mt-1 text-sm text-slate-400">{user?.email}</p>
            </div>

            <button
              type="button"
              onClick={logout}
              className="rounded-full border border-white/10 bg-slate-950/70 px-4 py-2 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-slate-900"
            >
              Logout
            </button>
          </div>
        </header>

        <main className="flex min-h-0 flex-1">
          <div className="mx-auto flex min-h-0 w-full max-w-4xl flex-1">
            <ChatContainer token={token} />
          </div>
        </main>
      </div>
    </div>
  )
}

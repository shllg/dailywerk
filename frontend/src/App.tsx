import { useEffect, useState } from 'react'

interface HealthResponse {
  status: string
  timestamp: string
  version: string
  ruby: string
}

function App() {
  const [health, setHealth] = useState<HealthResponse | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetch('/api/v1/health')
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        return res.json()
      })
      .then(setHealth)
      .catch((err) => setError(err.message))
  }, [])

  return (
    <div className="min-h-screen bg-gray-950 text-white flex items-center justify-center">
      <div className="max-w-md w-full mx-auto p-8">
        <h1 className="text-4xl font-bold mb-2">DailyWerk</h1>
        <p className="text-gray-400 mb-8">Full-stack is running.</p>

        {error && (
          <div className="bg-red-900/50 border border-red-700 rounded-lg p-4 mb-4">
            <p className="text-red-300 text-sm">API error: {error}</p>
          </div>
        )}

        {health && (
          <div className="bg-gray-900 border border-gray-800 rounded-lg p-6 space-y-3">
            <div className="flex justify-between">
              <span className="text-gray-400">Status</span>
              <span className="text-green-400 font-medium">{health.status}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Rails</span>
              <span className="font-mono text-sm">{health.version}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Ruby</span>
              <span className="font-mono text-sm">{health.ruby}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Timestamp</span>
              <span className="font-mono text-sm">{health.timestamp}</span>
            </div>
          </div>
        )}

        {!health && !error && (
          <p className="text-gray-500">Connecting to API...</p>
        )}
      </div>
    </div>
  )
}

export default App

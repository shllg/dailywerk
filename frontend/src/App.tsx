import { BrowserRouter, Navigate, Route, Routes } from 'react-router'
import { AppShell } from './components/layout'
import { AuthProvider } from './contexts/AuthContext'
import { useAuth } from './hooks/useAuth'
import { LoginPage } from './pages/LoginPage'
import { AgentsPage } from './pages/AgentsPage'
import { BillingPage } from './pages/BillingPage'
import { ChatPage } from './pages/ChatPage'
import { GatewaysPage } from './pages/GatewaysPage'
import { InboxPage } from './pages/InboxPage'
import { IntegrationsPage } from './pages/IntegrationsPage'
import { ProfilePage } from './pages/ProfilePage'
import { SettingsPage } from './pages/SettingsPage'
import { VaultPage } from './pages/VaultPage'

function AuthenticatedApp() {
  const { isAuthenticated } = useAuth()

  if (!isAuthenticated) {
    return <LoginPage />
  }

  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<Navigate replace to="/chat" />} />
        <Route path="/chat" element={<ChatPage />} />
        <Route path="/agents" element={<AgentsPage />} />
        <Route path="/gateways" element={<GatewaysPage />} />
        <Route path="/inbox" element={<InboxPage />} />
        <Route path="/vault" element={<VaultPage />} />
        <Route path="/billing" element={<BillingPage />} />
        <Route path="/integrations" element={<IntegrationsPage />} />
        <Route path="/profile" element={<ProfilePage />} />
        <Route path="/settings" element={<SettingsPage />} />
        <Route path="*" element={<Navigate replace to="/chat" />} />
      </Route>
    </Routes>
  )
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <AuthenticatedApp />
      </BrowserRouter>
    </AuthProvider>
  )
}

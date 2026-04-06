export interface AuthUser {
  id: string
  email: string
  name: string
}

export interface AuthWorkspace {
  id: string
  name: string
}

// Dev-only session response (POST /api/v1/sessions)
export interface SessionResponse {
  token: string
  user: AuthUser
  workspace: AuthWorkspace
}

// GET /api/v1/auth/provider
export interface AuthProviderResponse {
  provider: 'workos' | 'dev'
}

// GET /api/v1/auth/login
export interface AuthLoginResponse {
  authorization_url: string
}

// GET /api/v1/auth/me
export interface AuthMeResponse {
  access_token: string
  user: AuthUser
  workspace: AuthWorkspace
}

// POST /api/v1/auth/refresh
export interface AuthRefreshResponse {
  access_token: string
}

// DELETE /api/v1/auth/logout
export interface AuthLogoutResponse {
  logout_url?: string | null
}

// POST /api/v1/auth/websocket_ticket
export interface WebsocketTicketResponse {
  ticket: string
}

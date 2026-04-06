Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "ready", to: "ready#show"
  get "metrics", to: "metrics#show"

  mount GoodJob::Engine => "good_job"
  mount ActionCable.server => "/cable"

  # WorkOS OAuth callback (browser redirect, outside API namespace)
  get "auth/callback", to: "auth/callbacks#show"

  # WorkOS webhooks
  post "webhooks/workos", to: "webhooks/workos#handle"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"

      # WorkOS authentication
      get    "auth/login",            to: "auth#login"
      get    "auth/me",               to: "auth#me"
      post   "auth/refresh",          to: "auth#refresh"
      delete "auth/logout",           to: "auth#logout"
      get    "auth/provider",         to: "auth#provider"
      post   "auth/websocket_ticket", to: "auth#websocket_ticket"

      resource :chat, only: %i[show create], controller: "chat"
      resources :agents, only: %i[show update] do
        post :reset, on: :member
      end
      resources :memory_entries, path: "memory", only: %i[index show create update destroy]
      resources :sessions, only: :create
    end
  end
end

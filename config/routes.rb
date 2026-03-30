Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  mount GoodJob::Engine => "good_job"
  mount ActionCable.server => "/cable"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      resource :chat, only: %i[show create], controller: "chat"
      resources :sessions, only: :create
    end
  end
end

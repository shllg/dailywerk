Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  mount GoodJob::Engine => "good_job"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      resources :sessions, only: :create
    end
  end
end

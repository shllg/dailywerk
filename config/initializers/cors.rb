Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allowed_origins = CorsOrigins.load!(env: ENV, rails_env: Rails.env)

  allow do
    origins(*allowed_origins)

    resource "*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      credentials: true
  end
end

source "https://rubygems.org"

gem "rails", "~> 8.1.3"
gem "pg", "~> 1.1"

# Web server
gem "falcon"
gem "falcon-rails"

# Background jobs
gem "good_job"

# Cache + ActionCable pub/sub
gem "redis", ">= 5.0"

# CORS
gem "rack-cors"

# Active Storage S3
gem "aws-sdk-s3", require: false
gem "image_processing", "~> 1.2"

gem "tzinfo-data", platforms: %i[windows jruby]
gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  gem "rubocop-minitest", require: false
end

#!/usr/bin/env -S falcon host
# frozen_string_literal: true

load :rack

hostname = ENV.fetch("FALCON_HOST", "localhost")
port = ENV.fetch("FALCON_PORT", 3000)

rack hostname do
  endpoint Async::HTTP::Endpoint.parse("http://0.0.0.0:#{port}")
end

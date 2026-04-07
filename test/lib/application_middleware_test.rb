# frozen_string_literal: true

require "test_helper"

class ApplicationMiddlewareTest < ActiveSupport::TestCase
  test "api stack includes cookies middleware for auth cookies" do
    assert_includes middleware_classes, ActionDispatch::Cookies
  end

  test "api stack excludes session middleware" do
    refute_includes middleware_classes, ActionDispatch::Session::CookieStore
  end

  test "api stack excludes flash middleware" do
    refute_includes middleware_classes, ActionDispatch::Flash
  end

  test "api stack excludes method override middleware" do
    refute_includes middleware_classes, Rack::MethodOverride
  end

  private

  def middleware_classes
    Rails.application.middleware.middlewares.map(&:klass)
  end
end

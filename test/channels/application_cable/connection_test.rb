# frozen_string_literal: true

require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection

  setup do
    @user, @workspace = create_user_with_workspace(
      email: "cable-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Cable"
    )
    @original_consume = WebsocketTicketStore.method(:consume)
  end

  teardown do
    WebsocketTicketStore.define_singleton_method(:consume, @original_consume)
  end

  test "connects with a valid websocket ticket" do
    payload = {
      user_id: @user.id,
      workspace_id: @workspace.id
    }.to_json

    WebsocketTicketStore.define_singleton_method(:consume) do |ticket|
      ticket == "valid-ticket" ? payload : nil
    end

    connect params: { ticket: "valid-ticket" }

    assert_equal @user.id, connection.current_user.id
    assert_equal @workspace.id, connection.current_workspace.id
  end

  test "rejects malformed websocket ticket payloads" do
    WebsocketTicketStore.define_singleton_method(:consume) do |_ticket|
      "not-json"
    end

    assert_reject_connection do
      connect params: { ticket: "bad-ticket" }
    end
  end

  test "rejects requests without authentication params" do
    assert_reject_connection do
      connect params: {}
    end
  end
end

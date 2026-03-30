# frozen_string_literal: true

# Streams events for one workspace-scoped chat session.
class SessionChannel < ApplicationCable::Channel
  def subscribed
    session = Session.unscoped.find_by(id: params[:session_id], workspace: current_workspace)
    return reject unless session

    stream_from "session_#{session.id}"
  end
end

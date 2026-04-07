# frozen_string_literal: true

# Streams events for one workspace-scoped chat session.
class SessionChannel < ApplicationCable::Channel
  def subscribed
    session = Current.without_workspace_scoping do
      Session.find_by(id: params[:session_id], workspace: current_workspace)
    end
    return reject unless session

    stream_from "session_#{session.id}"
  end
end

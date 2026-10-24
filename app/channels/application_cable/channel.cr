class ApplicationCable::Channel < ActionCable::Channel::Base
  # The port stores identifiers as strings; narrow the connection to fetch the user id.
  def current_user_id : String?
    conn = @connection
    if conn.is_a?(ActionCable::Connection)
      conn.current_user
    end
  end
end

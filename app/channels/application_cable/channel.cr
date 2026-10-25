class ApplicationCable::Channel < ActionCable::Channel::Base
  # The port stores identifiers as strings; narrow the connection to fetch the user id.
  def current_user_id : String?
    conn = @connection
    if conn.is_a?(ActionCable::Connection)
      conn.current_user
    end
  end

  # identified_by :current_user (connection) — resolve the User record.
  def current_user : User?
    return nil unless (uid = current_user_id)
    uid.to_i64?.try { |id| User.find?(id) }
  end
end

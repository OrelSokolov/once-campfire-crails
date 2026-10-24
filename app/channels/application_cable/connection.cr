# Cable connection authorization: cookie session_token → user. The identifier is the
# user id as a string (the port stores identifiers as strings).
class ActionCable::Connection
  identified_by :current_user

  def connect : Nil
    if (uid = session_user_id)
      self.current_user = uid
    else
      reject_unauthorized_connection!
    end
  end

  private def session_user_id : String?
    request = @request
    return nil unless request

    context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
    jar = ActionController::Cookies.new(context)
    raw = jar.signed["session_token"]?
    token = Session.token_from_signed_jar(raw)
    return nil unless token

    Session.where("token = ?", token).take.try(&.user_id).try(&.to_s)
  end
end

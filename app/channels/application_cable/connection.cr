# Авторизация cable-соединения: cookie session_token → user (референс:
# ApplicationCable::Connection + Authentication::SessionLookup).
# Identifier — id пользователя строкой (порт хранит identifiers строками).
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
    token = case raw
            when String then raw
            when JSON::Any then raw.as_s?
            else nil
            end
    return nil unless token

    Session.where("token = ?", token).take.try(&.user_id).try(&.to_s)
  end
end

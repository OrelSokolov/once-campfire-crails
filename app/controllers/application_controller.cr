abstract class ApplicationController < ActionController::Base
  before_action :require_authentication

  def current_session : Session?
    raw = cookies.signed["session_token"]?
    token = case raw
            when String then raw
            when JSON::Any then raw.as_s? # signed jar decodes JSON-wrapped values
            else nil
            end
    return nil unless token
    Session.where("token = ?", token).take
  end

  def current_user : User?
    session = current_session
    return nil unless session
    user_id = session.user_id
    return nil unless user_id
    User.find?(user_id)
  end

  def require_authentication : Nil
    redirect_to "/session/new" unless current_user
  end

  def remote_ip : String?
    request.headers["X-Forwarded-For"]?.try(&.split(',').first?.try(&.strip)) ||
      request.headers["Remote-Addr"]? || "127.0.0.1"
  end
end

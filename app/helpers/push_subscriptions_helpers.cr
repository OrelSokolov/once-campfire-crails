# PushSubscriptionsHelpers: ERB helpers for app/views/users/push_subscriptions/index.html.erb.
module PushSubscriptionsHelpers
  include ActionController::Helper
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("push-subscriptions",
      "Push notification subscriptions",
      nav_html: nav_back_to(last_room_visited_path).raw))
  end

  # Non-browser or empty UA (curl, nil) yields an empty string.
  def user_agent_summary(user_agent : String?) : String
    return "" if user_agent.to_s.empty?
    agent = UserAgent.new(user_agent.to_s)
    return "" if agent.browser.empty?
    "#{agent.browser} #{agent.version} on #{agent.platform}".strip
  end

  private def last_room_visited_path : String
    user = current_user!
    room = nil
    if last = cookies[:last_room]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= Room.visible_for(user).order("id").first?
    room ? room_path(room.id!) : root_path
  end
end

# Minimal port of the useragent gem: browser is the first known product
# token in the UA, version is its version token, platform comes from
# ApplicationPlatform.
class UserAgent
  BROWSERS = %w[Firefox FxiOS Chrome Opera MSIE Edg Edge Safari]

  def initialize(@ua : String)
  end

  def browser : String
    browser_token.try(&.split('/')[0]).to_s
  end

  def version : String
    parts = browser_token.to_s.split('/', 2)
    parts.size > 1 ? parts[1] : ""
  end

  def platform : String
    ApplicationPlatform.new(@ua).operating_system
  end

  private def browser_token : String?
    @ua.split(' ').find { |token| BROWSERS.includes?(token.split('/')[0]) }
  end
end

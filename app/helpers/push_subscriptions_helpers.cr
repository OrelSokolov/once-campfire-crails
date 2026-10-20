# PushSubscriptionsHelpers — ERB-хелперы app/views/users/
# push_subscriptions/index.html.erb: каркас страницы (nav-назад —
# link_back_to_last_room_visited референса) и разбор User-Agent
# подписки (UserAgent.parse: browser/version/platform).
# Включается в Users::PushSubscriptionsController; icon/page_close —
# ViewHelpers.
module PushSubscriptionsHelpers
  # head + body + nav + main; nav — «Go Back» к последней посещённой
  # комнате (rooms_helper: link_back_to_last_room_visited).
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("push-subscriptions",
      "Push notification subscriptions", current_user.not_nil!,
      nav_html: ChatLayout.nav_back(last_room_visited_path)))
  end

  # _push_subscription.html.erb: <strong>Browser version on Platform</strong>
  # (useragent-гем). Небраузерный/пустой UA (curl, nil) — пустая строка
  # (агент не определяется — « on » не печатаем).
  def user_agent_summary(user_agent : String?) : String
    return "" if user_agent.to_s.empty?
    agent = UserAgent.new(user_agent.to_s)
    return "" if agent.browser.empty?
    "#{agent.browser} #{agent.version} on #{agent.platform}".strip
  end

  # TrackedRoomVisit (rooms_helper): cookie last_room (если комната
  # видима пользователю), иначе первая видимая; корень — когда видимых
  # комнат нет. Как AccountsHelpers#last_room_visited_path.
  private def last_room_visited_path : String
    user = current_user.not_nil!
    room = nil
    if last = cookies["last_room"]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= Room.visible_for(user).order("id").first?
    room ? room_path(room.id.not_nil!) : root_path
  end
end

# Мини-порт useragent-гема для списковой строки подписки: browser —
# первый известный продукт в UA, version — его токен версии, platform —
# классификация PlatformAgent (ApplicationPlatform референса).
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
    PlatformAgent.new(@ua).operating_system
  end

  private def browser_token : String?
    @ua.split(' ').find { |token| BROWSERS.includes?(token.split('/')[0]) }
  end
end

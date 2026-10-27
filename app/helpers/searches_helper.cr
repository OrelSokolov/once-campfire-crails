module SearchesHelper
  include ActionController::Helper
  def page_open : ERB::SafeString
    page_shell_open("Search", body_class: "sidebar searches",
      nav_html: search_nav(query, messages.size, recents))
  end

  # The template registers :footer itself (content_for :footer); the
  # sidebar holds the recent searches list.
  def page_close : ERB::SafeString
    page_shell_close(sidebar_html: %(<div class="rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar">\n) + recent_searches_html(recents) + %(</div>))
  end

  # Oracle searches/index.html.erb: `render partial: "messages/message",
  # collection: @messages, cached: ...` inside search_results_tag. Search
  # results span rooms, so each miss renders against its own room
  # (room: nil — ChatLayout.messages_to loads them with one IN query).
  # `cached:` carries the oracle call shape; the port's cache is
  # epoch-keyed (known-gaps).
  def render(partial : String, *, collection : Array(Message),
             cached : Bool = true) : ERB::SafeString
    raise ArgumentError.new("Missing partial #{partial.inspect}") unless partial == "messages/message"
    ERB::SafeString.new(
      ChatLayout.messages_html(collection, epoch, nil, origin))
  end

  def search_icon_src : String
    ChatLayout.asset("search.svg")
  end

  def search_nav(query : String, count : Int32, recents : Array(String)) : String
    render(partial: "searches/nav",
      locals: {"query" => query, "count" => count, "recents" => recents}).raw
  end

  def recent_searches_html(recents : Array(String)) : String
    render(partial: "searches/recent_searches", locals: {"recents" => recents}).raw
  end
end

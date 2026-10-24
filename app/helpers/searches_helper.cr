module SearchesHelper
  include ActionController::Helper
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("search", "Search",
      body_class: "sidebar searches", nav_html: search_nav(query, messages.size, recents)))
  end

  def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close(content_for(:footer).to_s,
      %(<div class="rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar">\n) + recent_searches_html(recents) + %(</div>)))
  end

  def messages_html : ERB::SafeString
    ERB::SafeString.new(String.build { |io|
      ChatLayout.messages_to(io, messages, epoch, nil, origin)
    })
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

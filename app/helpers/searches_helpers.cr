# SearchesHelpers — ERB-хелперы app/views/searches/show.html.erb:
# head+nav поиска, выдача сообщений, футер с composer'ом поиска и recents.
# Включается в SearchesController; общий icon — ViewHelpers, page_close
# перекрыт (свой футер и aside с недавними запросами).
module SearchesHelpers
  # head + body.sidebar.searches + nav с чипом запроса и recents.
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("search", "Search", user.not_nil!,
      body_class: "sidebar searches", nav_html: search_nav(query, messages.size, recents)))
  end

  # footer(content_for :footer из шаблона — composer поиска) +
  # aside(recents) + app-logo (layouts/_body_close).
  def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close(content_for(:footer).to_s,
      %(<div class="rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar">\n) + recent_searches_html(recents) + %(</div>)))
  end

  # Коллекция сообщений (fragment-кэш внутри messages_to).
  def messages_html : ERB::SafeString
    ERB::SafeString.new(String.build { |io|
      ChatLayout.messages_to(io, messages, epoch, nil, origin)
    })
  end

  def search_icon_src : String
    ChatLayout.asset("search.svg")
  end

  # search_nav.eta → searches/_nav.html.erb: чип запроса с количеством +
  # recents. Ссылки recents — литеральные <a> (порядок атрибутов вывода
  # порта: class до href), форма clear — button_to-подобный литерал.
  def search_nav(query : String, count : Int32, recents : Array(String)) : String
    render(partial: "searches/nav",
      locals: {"query" => query, "count" => count, "recents" => recents}).raw
  end

  # recent_searches.eta → searches/_recent_searches.html.erb: ссылки на
  # последние запросы (6 пробелов между, \n после последней) + очистка
  # (broom). Рендерится из search_nav И из page_close (aside).
  def recent_searches_html(recents : Array(String)) : String
    render(partial: "searches/recent_searches", locals: {"recents" => recents}).raw
  end
end

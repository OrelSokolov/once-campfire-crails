# SearchesHelpers — ERB-хелперы app/views/searches/show.html.erb:
# head+nav поиска, выдача сообщений, футер с composer'ом поиска и recents.
# Включается в SearchesController; общий icon — ViewHelpers, page_close
# перекрыт (свой футер и aside с недавними запросами).
module SearchesHelpers
  # head + body.sidebar.searches + nav с чипом запроса и recents.
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("search", "Search: #{query}", user.not_nil!,
      body_class: "sidebar searches", nav_html: search_nav(query, messages.size, recents)))
  end

  # footer(content_for :footer из шаблона — composer поиска) +
  # aside(recents) + app-logo (layouts/_body_close).
  def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close(content_for(:footer).to_s,
      %(<div class="rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar">) + recent_searches_html(recents) + %(</div>)))
  end

  # Коллекция сообщений (fragment-кэш внутри messages_to).
  def messages_html : ERB::SafeString
    ERB::SafeString.new(String.build { |io|
      ChatLayout.messages_to(io, messages, epoch, nil, origin) })
  end

  def search_icon_src : String
    ChatLayout.asset("search.svg")
  end

  # search_nav.eta: чип запроса с количеством + recents.
  def search_nav(query : String, count : Int32, recents : Array(String)) : String
    String.build do |io|
      unless query.empty?
        io << %(<div class="searches__query flex align-center gap pad-block-start-half">)
        io << %(<div class="btn btn--reversed btn--faux align-center gap txt-nowrap">)
        io << %(<span class="overflow-ellipsis">“) << HTML.escape(query) << %(”</span>)
        io << %(<span class="flex-item-no-shrink">) << count << %(</span></div></div>)
      end
      io << %(<div class="searches__recents align-center gap pad-block-half overflow-y overflow-hide-scrollbar">)
      io << recent_searches_html(recents)
      io << %(</div>)
    end
  end

  # recent_searches.eta: ссылки на последние запросы + очистка (broom).
  def recent_searches_html(recents : Array(String)) : String
    String.build do |io|
      recents.each do |q|
        io << %(<a class="align-center gap room btn txt-nowrap" href="/searches?q=)
        io << URI.encode_www_form(q) << %("><span class="overflow-ellipsis">“)
        io << HTML.escape(q) << %(”</span></a>)
      end
      unless recents.empty?
        io << %(<form class="button_to" method="post" action="/searches/clear">)
        io << %(<input type="hidden" name="_method" value="delete">)
        io << %(<button class="btn searches__btn" )
        io << %(data-turbo-confirm="Are you sure you want to clear your recent searches?" )
        io << %(type="submit">) << ChatLayout.icon("broom.svg")
        io << %(<span class="for-screen-reader">Clear recent searches</span></button></form>)
      end
    end
  end
end

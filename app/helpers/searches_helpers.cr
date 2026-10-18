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

  # search_nav.eta: чип запроса с количеством + recents.
  def search_nav(query : String, count : Int32, recents : Array(String)) : String
    String.build do |io|
      unless query.empty?
        io << %(<div class="searches__query flex align-center gap pad-block-start-half">\n)
        io << %(<div class="btn btn--reversed btn--faux align-center gap txt-nowrap">\n)
        io << %(<span class="overflow-ellipsis">“) << HTML.escape(query) << %(”</span>\n)
        io << %(<span class="flex-item-no-shrink">) << count << %(</span>\n)
        io << %(</div>    </div>\n)
      end
      io << %(<div class="searches__recents align-center gap pad-block-half overflow-y overflow-hide-scrollbar">\n)
      io << recent_searches_html(recents)
      io << %(</div>)
    end
  end

  # recent_searches.eta: ссылки на последние запросы + очистка (broom).
  # Переносы/пробелы — как в выводе Rails-ERB (артефакты): ссылки через
  # 6 пробелов, после последней — \n, форма с полным URL (clear_searches_url),
  # broom без width/height, хвост "  " перед закрывающим </div> вызывающего.
  def recent_searches_html(recents : Array(String)) : String
    String.build do |io|
      links = recents.map do |q|
        %(<a class="align-center gap room btn txt-nowrap" href="/searches?q=#{URI.encode_www_form(q)}">\n) +
          %(<span class="overflow-ellipsis">“#{HTML.escape(q)}”</span>\n</a>)
      end
      io << links.join("      ")
      unless recents.empty?
        io << "\n"
        io << %(<form action=") << origin << %(/searches/clear" class="button_to" method="post">)
        io << %(<input name="_method" type="hidden" value="delete">)
        io << %(<button class="btn searches__btn" )
        io << %(data-turbo-confirm="Are you sure you want to clear your recent searches?" )
        io << %(type="submit">\n)
        io << %(<img aria-hidden="true" src="#{ChatLayout.asset("broom.svg")}">\n)
        io << %(<span class="for-screen-reader">Clear recent searches</span>\n)
        io << %(</button></form>  )
      end
    end
  end
end

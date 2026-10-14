# GET /searches?q=coffee — поиск по FTS5 (контракт: ID = MATCH с join по
# membership/email из сида, максимум 100, вывод в порядке ID).
class SearchesController < ApplicationController
  def show
    user = current_user.not_nil!
    query = params["q"]?.to_s.strip

    messages = if query.empty?
      [] of Message
    else
      # Same shape as the harness's seed SQL: messages visible to the user,
      # newest 100 matches by id, displayed in id order.
      Message.where(
        %(id IN (SELECT m.id FROM messages m
                 JOIN message_search_index idx ON idx.rowid = m.id
                 JOIN memberships mm ON mm.room_id = m.room_id
                 WHERE mm.user_id = ? AND message_search_index MATCH ?
                 ORDER BY m.id DESC LIMIT 100)),
        user.id.not_nil!, query)
        .order("id ASC").to_a
    end

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.head("Search: #{query}", user, nil, chat: false)
      io << %(<body class="search">\n<main id="main-content">\n)
      io << %(<div id="search-results" class="messages searches__results" data-controller="search-results" )
      io << %(data-search-results-target="messages" data-search-results-me-class="message--me" )
      io << %(data-search-results-threaded-class="message--threaded" )
      io << %(data-search-results-mentioned-class="message--mentioned" )
      io << %(data-search-results-formatted-class="message--formatted" data-query=") << HTML.escape(query) << %(">\n)
      messages.each do |m|
        room = Room.find?(m.room_id.not_nil!)
        next unless room
        io << ChatLayout.message_dom(m, room, User.find?(m.creator_id.not_nil!))
      end
      io << %(</div>\n)
      io << %(</main>\n</body>\n</html>\n)
    end)
  end
end

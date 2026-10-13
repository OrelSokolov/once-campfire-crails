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
      io << "<!doctype html>\n<html>\n<head><title>Search</title></head>\n<body>\n"
      io << %(<section class="search_results" data-query=") << HTML.escape(query) << %("\n)
      io << %(  <ol class="results">\n)
      messages.each do |m|
        io << %(    <li><article id="message_#{m.id}" data-message-id="#{m.id}" data-client-message-id=")
        io << HTML.escape(m.client_message_id.to_s)
        io << %("\n      >)
        io << %(<div class="message-body">) << m.indexed_body.to_s << "</div>\n"
        io << "    </article></li>\n"
      end
      io << "  </ol>\n</section>\n</body>\n</html>\n"
    end)
  end
end

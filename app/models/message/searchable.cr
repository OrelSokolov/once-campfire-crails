require "../application_record"

# Message::Searchable (message/searchable.rb): зеркалирование тел
# сообщений в FTS5-индекс message_search_index + разбор поискового
# запроса.
class Message
  module Searchable
    def self.insert_in_index(conn, message_id : Int64, body : String) : Nil
      conn.exec(
        "INSERT INTO message_search_index (rowid, body) VALUES ($1, $2)",
        message_id, body)
    end

    def self.update_in_index(conn, message_id : Int64, body : String) : Nil
      conn.exec("DELETE FROM message_search_index WHERE rowid = ?", message_id)
      insert_in_index(conn, message_id, body)
    end

    def self.remove_from_index(conn, message_id : Int64) : Nil
      conn.exec("DELETE FROM message_search_index WHERE rowid = ?", message_id)
    end

    # match_terms: каждое слово запроса берётся в кавычки FTS5 (двойные
    # внутри удваиваются) — иначе запрос из операторов ("AND", "salt
    # AND", незакрытая кавычка) даёт синтаксическую ошибку FTS5 и 500
    # вместо выдачи.
    def self.match_terms(query : String) : String
      query.split.map { |word| %("#{word.gsub('"', %q(""))}") }.join(" ")
    end
  end
end

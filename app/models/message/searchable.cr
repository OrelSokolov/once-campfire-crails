require "../application_record"

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

    # after_destroy_commit :remove_from_index — the instance form.
    def remove_from_index : Nil
      Searchable.remove_from_index(ActiveRecord::Base.connection, id.not_nil!)
    end

    # Quotes each word, so that FTS5 searches for AND, OR, NOT and NEAR rather than
    # parsing them as operators, which fails on a query like "AND" or "salt AND".
    def self.match_terms(query : String) : String
      query.split.map { |word| %("#{word.gsub('"', %q(""))}") }.join(" ")
    end
  end
  include Searchable
end

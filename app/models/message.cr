# Message bodies live in ActionText (action_text_rich_texts) and are
# mirrored into the FTS5 message_search_index by the reference app;
# the seed database carries both.
class Message < ActiveRecord::Base
  belongs_to :room, touch: true
  belongs_to :creator, class_name: "User"
  has_many :boosts, foreign_key: "message_id"

  # ActionText body (record_type='Message', name='body').
  def rich_text : ActionTextRichText?
    ActionTextRichText
      .where("record_type = ? AND record_id = ? AND name = ?", "Message", id.not_nil!, "body")
      .take
  end

  def body : String?
    rich_text.try(&.body)
  end

  # Search-index copy (FTS5, rowid = message id) — the authoritative body
  # text for search results and contract word content.
  def indexed_body : String?
    row = ActiveRecord::Base.connection.query_one?(
      "SELECT body FROM message_search_index WHERE rowid = ?", id,
      as: String)
    row
  end
end

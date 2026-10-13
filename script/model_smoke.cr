# Разовый smoke моделей на каноническом сиде (не компилируется в bin/app):
#   crystal run script/model_smoke.cr
require "../src/app_boot_models"

david = User.where("email_address = ?", "david@37signals.com").first!.not_nil!
puts "david: id=#{david.id} name=#{david.name.inspect} role=#{david.role}"

# bisect: same rich_text query at top level, before anything else
top = ActionTextRichText.where(
  "record_type = ? AND record_id = ? AND name = ?",
  "Message", 925779126_i64, "body").first?
puts "top-level rich_text: #{top.try(&.id).inspect}"

rooms = Room.visible_for(david).order("id").to_a
puts "visible rooms for david: #{rooms.size}"
rooms.each { |r| puts "  ##{r.id} #{r.name.inspect} (#{r.type})" }

# Labels are the bench's source of truth (labels.json), not room names:
# rooms.watercooler points at the seeded room the harness calls watercooler.
watercooler_id = 486777696_i64
puts "watercooler (labels.rooms.watercooler): #{watercooler_id}"

if wid = watercooler_id
  msgs = Message.where("room_id = ?", wid).order("created_at DESC").limit(3).to_a.reverse
  msgs.each do |m|
    puts "msg ##{m.id} by user##{m.creator_id} cmid=#{m.client_message_id.inspect}"
    rt = m.rich_text
    raw = ActiveRecord::Base.connection.query_one?(
      "SELECT body FROM action_text_rich_texts WHERE record_type = $1 AND record_id = $2 AND name = $3 LIMIT 1",
      "Message", m.id.not_nil!, "body", as: String)
    puts "  rich_text=#{rt.try(&.id).inspect} body_attr=#{rt.try(&.body).to_s[0, 30].inspect} raw=#{raw.to_s[0, 30].inspect}"
    puts "  body(FTS5):       #{m.indexed_body.to_s[0, 60].inspect}"
  end
end

# FTS5 parity with CLI for 'coffee'
ar_hits = ActiveRecord::Base.connection.query_all(
  "SELECT rowid FROM message_search_index WHERE message_search_index MATCH 'coffee' ORDER BY rowid", as: Int64)
cli_hits = `sqlite3 -readonly db/development.sqlite3 "SELECT rowid FROM message_search_index WHERE message_search_index MATCH 'coffee' ORDER BY rowid;"`
  .strip.split('\n').reject(&.empty?).map(&.to_i64)
puts "fts5 coffee: ar=#{ar_hits.size} cli=#{cli_hits.size} match=#{ar_hits == cli_hits}"

# Avatar blob for jason (avatar_tokens.jason → user 149087659)
jason = User.where("email_address = ?", "jason@37signals.com").first?.not_nil!
puts "jason id=#{jason.id.inspect} (expect 149087659)"
inline = ActiveStorageAttachment.where(
  "record_type = ? AND record_id = ? AND name = ?",
  "User", jason.id.not_nil!, "avatar").first?
puts "inline attachment: #{inline.try(&.blob_id).inspect}"
if blob = jason.avatar_blob
  puts "jason avatar: key=#{blob.key} ct=#{blob.content_type} bytes=#{blob.byte_size}"
else
  puts "jason avatar: none"
end

# Session record (seed has 1)
s = Session.all.first?
puts "session: user=#{s.try(&.user_id)} token_prefix=#{s.try(&.token.to_s[0, 8]).inspect}"

# Разовый smoke: полная сборка страницы комнаты как в rooms#show —
# проверка итоговых байтов (переносы строк в конце страницы).
#   crystal run script/render_smoke.cr
require "../src/app_boot_models"
require "../app/models/application_platform"
require "../app/models/fragment_cache"
require "../app/helpers/chat_layout"
require "../app/helpers/chat_erb"

ActiveRecord::Base.establish_connection(
  "sqlite3:///tmp/smoke-seed/db/production.sqlite3")
CRails.application.initialize!
require "../config/cable"

david = User.where("email_address = ?", "david@37signals.com").first?.not_nil!
room = Room.order("id").first?.not_nil!

messages = Message.where("room_id = ?", room.id.not_nil!)
  .order("created_at DESC").limit(5).to_a.reverse
# Page shell assembly moved to layouts/application (rooms#show renders
# through __render_layout) — this script keeps only the message_dom checks
# below.
_ = messages

# ——— звуки и og-embed: presentation конкретных сообщений сида ———
[933434492_i64, 933434493_i64, 933434494_i64, 933434495_i64, 933434496_i64].each do |mid|
  m = Message.find?(mid)
  next puts "message #{mid}: not found" unless m
  room2 = Room.find?(m.room_id.not_nil!)
  next puts "message #{mid}: room missing" unless room2
  out = ChatLayout.message_dom(m, room2, User.find?(m.creator_id.not_nil!), base_url: "http://127.0.0.1:1")
  pres = out[/id="presentation_message_#{mid}"[^>]*>\n(.*?)\n<\/div>/m, 1]?.to_s
  puts "== message #{mid}:\n#{pres[0, 700]}"
end

# ——— нормализованная сверка presentation с Rails-серверным выводом ———
[933434492_i64, 933434493_i64, 933434494_i64, 933434495_i64, 933434496_i64].each do |mid|
  m2 = Message.find?(mid).not_nil!
  dom = ChatLayout.message_dom(m2, Room.find?(m2.room_id.not_nil!).not_nil!,
    User.find?(m2.creator_id.not_nil!), base_url: "http://127.0.0.1:1")
  pres2 = dom[/id="presentation_message_#{mid}"[^>]*>\n(.*)\n<\/div>\n<turbo-frame id="boosting/m, 1].to_s
  norm = pres2.split("\n").reject { |l| l.strip.empty? }.map(&.strip).join("\n")
  File.write("/tmp/crails_#{mid}.txt", norm)
  rails_norm = File.read("/tmp/rails_#{mid}.txt")
  puts "message #{mid}: #{norm == rails_norm ? "IDENTICAL" : "DIFF"}"
end


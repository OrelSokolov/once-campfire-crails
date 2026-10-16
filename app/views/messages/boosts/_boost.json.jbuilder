# Порт messages/boosts/_boost.json.jbuilder референса: id, content,
# created_at, booster через users/_user, message {id, url}.
json.id boost.id
json.content boost.content
json.created_at ChatLayout.iso8601_ms(boost.created_at.not_nil!)
json.booster boost.booster, partial: "users/user", as_local: :user
json.message do
  json.id boost.message_id
  json.url jb_origin + "/rooms/#{boost.message.not_nil!.room_id}/messages/#{boost.message_id}"
end

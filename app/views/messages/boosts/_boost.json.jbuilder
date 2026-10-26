json.cache! boost do
  json.extract! boost, :id, :content

  json.created_at ChatLayout.iso8601_ms(boost.created_at!)

  json.booster boost.booster, partial: "users/user", as_local: :user

  json.message do
    json.id boost.message_id
    json.url room_message_url(boost.message.not_nil!.room, boost.message)
  end
end

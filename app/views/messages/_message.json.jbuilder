json.cache! message do
  json.extract! message, :id

  json.created_at ChatLayout.iso8601_ms(message.created_at!)

  json.body do
    plain = MessageCreator.plain_text(message.body.to_s)
    if plain.empty?
      attachment = ChatLayout.attachments_for([message.id!])[message.id!]?
      plain = attachment.try(&.filename).to_s
    end
    json.plain_text plain
    json.html %(<div class="lexxy-content">#{message.body.to_s}</div>)
  end

  json.creator message.creator, partial: "users/user", as_local: :user

  json.room do
    json.id message.room_id
  end

  json.url room_message_url(message.room, message)
end

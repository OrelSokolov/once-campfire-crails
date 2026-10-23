# Порт messages/by_bots/show.json.jbuilder референса: одно сообщение
# через messages/_message.
json.jb_origin = origin
json.partial! "messages/message", {"message" => @message}

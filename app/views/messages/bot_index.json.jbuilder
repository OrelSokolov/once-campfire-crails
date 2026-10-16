# Порт messages/by_bots/index.json.jbuilder референса: коллекция
# сообщений через messages/_message (as: → as_local: — порт).
json.jb_origin = origin
json.array! @messages, partial: "messages/message", as_local: :message

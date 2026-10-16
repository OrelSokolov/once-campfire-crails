# Порт messages/boosts/by_bots/show.json.jbuilder референса: ответ
# bot-создания буста — boosts/_boost.
json.jb_origin = origin
json.partial! "messages/boosts/boost", {"boost" => @boost}

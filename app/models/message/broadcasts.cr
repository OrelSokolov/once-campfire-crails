require "../application_record"

# Message::Broadcasts (message/broadcasts.rb): turbo-stream broadcast
# создания/удаления сообщения в стрим [room, "messages"].
class Message
  module Broadcasts
    # broadcast_create референса: broadcast_append_to room, :messages,
    # target: [ room, :messages ], html: … Cable-фрейм — без хвостового
    # \n (он только в HTTP-ответе create.turbo_stream.erb, который
    # собирает контроллер). Хвостовой \n message_dom срезаем: у Rails
    # html = render_to_string партиала, а Erubi глотает переводы строк
    # после <% end %> — партиал кончается ровно </div>. Иначе Turbo
    # аппендит в контейнер текстовый узел-пробел после сообщения (видно
    # в браузерном DOM: </div></div> склеены у оракула, у нас с переносом).
    def self.broadcast_create(room : Room, message : Message, author : User,
                              attachment : ChatLayout::Attachment? = nil,
                              base_url : String = "") : Nil
      Turbo::StreamsChannel.broadcast_append_to([room, "messages"],
        target: "messages_#{room.dom_id}",
        html: ChatLayout.message_dom(message, room, author, attachment, base_url: base_url).chomp)
    end

    # broadcast_remove: стрим [room, "messages"], target — dom_id
    # сообщения (cable-фрейм, без хвостового \n). Комната может быть уже
    # удалена — тогда стрима нет и убирать нечего.
    def self.broadcast_remove(room_id : Int64, message_id : Int64) : Nil
      if (room = Room.find?(room_id))
        Turbo::StreamsChannel.broadcast_remove_to([room, "messages"],
          target: "message_#{message_id}")
      end
    end
  end
end

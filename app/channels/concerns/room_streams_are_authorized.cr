# Prepended onto Turbo::StreamsChannel (room_streams_are_authorized.rb
# оракула; подключение — config/initializers/turbo_streams_authorization).
# The subscriber names the channel it wants, so authorizing room messages
# only in RoomMessagesChannel would leave the stock channel as a way
# around it: same signed stream name, no membership check. Turn those
# names away here and RoomMessagesChannel becomes the only door.
#
# Crystal не имеет `prepend` — вместо модуля класс reopened с guard:
# подписка на защищённый (:messages) стрим через стоковый
# Turbo::StreamsChannel отклоняется, остальные идут базовой логикой.
require "../room_messages_channel"

class Turbo::StreamsChannel
  def subscribed : Nil
    if (signed = params["signed_stream_name"]?) &&
       (stream_name = Turbo::StreamsChannel.verified_stream_name(signed)) &&
       RoomMessagesChannel.guarded_stream?(stream_name)
      reject
    else
      # Тело базового Turbo::StreamsChannel#subscribed (broadcasts.cr).
      if (signed = params["signed_stream_name"]?) &&
         (stream_name = Turbo::StreamsChannel.verified_stream_name(signed))
        stream_from(stream_name)
      else
        reject
      end
    end
  end
end

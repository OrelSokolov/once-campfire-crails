# Prepended onto Turbo::StreamsChannel. The subscriber names the channel it wants, so
# authorizing room messages only in RoomMessagesChannel would leave the stock channel as
# a way around it: same signed stream name, no membership check. Turn those names away
# here and RoomMessagesChannel becomes the only door.
#
# Crystal has no `prepend` — the class is reopened with a guard instead: subscribing to a
# guarded (:messages) stream via the stock Turbo::StreamsChannel is rejected, everything
# else goes through the base logic.
require "../room_messages_channel"

class Turbo::StreamsChannel
  def subscribed : Nil
    if (signed = params["signed_stream_name"]?) &&
       (stream_name = Turbo::StreamsChannel.verified_stream_name(signed)) &&
       RoomMessagesChannel.guarded_stream?(stream_name)
      reject
    else
      # Body of the stock Turbo::StreamsChannel#subscribed (no super in a reopened class).
      if (signed = params["signed_stream_name"]?) &&
         (stream_name = Turbo::StreamsChannel.verified_stream_name(signed))
        stream_from(stream_name)
      else
        reject
      end
    end
  end
end

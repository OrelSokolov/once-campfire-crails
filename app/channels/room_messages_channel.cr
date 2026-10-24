require "./room_channel"
# Authorizes the room message stream when the subscription is made, so that revoking a
# membership actually stops delivery.
#
# Turbo's stock channel verifies only the signature on the stream name. That name carries
# no expiry and no binding to a user, so one harvested while a member keeps working after
# the membership is gone. Reconnecting makes it worse rather than better: revoking a
# membership disconnects the user with reconnect: true, and the client then replays its
# subscriptions on the fresh socket.
#
# The room is derived from the verified stream name rather than taken as a parameter, so
# there's nothing for a subscriber to point somewhere else. The subscriber also doesn't
# get to choose the channel: Turbo::StreamsChannel turns these stream names away, so this
# is the only way onto them. See config/initializers/turbo_streams_authorization.rb.
class RoomMessagesChannel < ApplicationCable::Channel
  STREAM_SUFFIX = "messages"

  # True for the stream names this channel exists to guard, whoever is asking.
  def self.guarded_stream?(stream_name : String?) : Bool
    !!stream_name.try { |s| s.split(":", 2)[1]? == STREAM_SUFFIX }
  end

  def subscribed : Nil
    stream_name = verified_stream_name_from_params
    if stream_name && subscribable_room?(stream_name)
      stream_from(stream_name)
    else
      reject
    end
  end

  private def verified_stream_name_from_params : String?
    signed = params["signed_stream_name"]?
    return nil unless signed
    Turbo::Streams::StreamName.verified_stream_name(signed)
  end

  private def subscribable_room?(stream_name : String) : Bool
    gid_param, suffix = stream_name.split(":", 2)
    return false unless suffix == STREAM_SUFFIX

    gid = begin
      Base64.decode_string(pad64(gid_param.tr("-_", "+/")))
    rescue
      return false
    end
    return false unless match = gid.match(/\Agid:\/\/campfire\/[\w:]+\/(\d+)\z/)
    room_id = match[1].to_i64

    uid = current_user_id
    return false unless uid

    Membership.where("room_id = ? AND user_id = ?", room_id, uid).exists?
  end

  private def pad64(s : String) : String
    s + "=" * ((4 - s.size % 4) % 4)
  end
end

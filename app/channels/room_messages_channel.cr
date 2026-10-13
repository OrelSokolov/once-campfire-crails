# RoomMessagesChannel — авторизация стрима сообщений комнаты (референс:
# app/channels/room_messages_channel.rb). Комната выводится из
# верифицированного имени стрима, подписчик не выбирает ни канал, ни
# комнату; членство проверяется при подписке — отзыв membership останав-
# ливает доставку.
class RoomMessagesChannel < ApplicationCable::Channel
  STREAM_SUFFIX = "messages"

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

  # "<b64url(gid)>:messages" → комната, видимая текущему пользователю.
  private def subscribable_room?(stream_name : String) : Bool
    gid_param, suffix = stream_name.split(":", 2)
    return false unless suffix == STREAM_SUFFIX

    gid = begin
      Base64.decode_string(pad64(gid_param.tr("-_", "+/")))
    rescue
      return false
    end
    return false unless match = gid.match(/\Agid:\/\/campfire\/Room\/(\d+)\z/)
    room_id = match[1].to_i64

    uid = current_user_id
    return false unless uid

    Membership.where("room_id = ? AND user_id = ?", room_id, uid).exists?
  end

  private def pad64(s : String) : String
    s + "=" * ((4 - s.size % 4) % 4)
  end
end

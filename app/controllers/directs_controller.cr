# /rooms/directs — личные чаты (референс: registerRoomForms kind=
# "directs" + direct_new.eta): new — форма автокомплита в turbo-frame
# direct_rooms_control; create — найти существующую direct-комнату с
# ровно этим набором участников или создать (membership "everything").
class DirectsController < ApplicationController
  # GET /rooms/directs/new — форма (подменяет direct_rooms_control в
  # сайдбаре через data-turbo-frame="_self").
  def new
    user = current_user.not_nil!
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.head("New ping", user, nil, chat: false)
      io << %(<body>\n)
      io << %(<turbo-frame id="direct_rooms_control" target="_top">)
      io << %(<div class="directs directs--new flex flex-column gap">)
      io << %(<form class="flex gap flex-item-grow" data-controller="form" )
      io << %(data-action="keydown.esc->form#cancel" action="/rooms/directs" )
      io << %(accept-charset="UTF-8" method="post">)
      io << %(<a class="btn flex-item-no-shrink" data-turbo-frame="user_sidebar" )
      io << %(data-form-target="cancel" href="/users/me/sidebar">)
      io << ChatLayout.icon("arrow-left.svg")
      io << %(<span class="for-screen-reader">Cancel changes</span></a>\n)
      io << %(<section class="autocomplete__container unpad input input--actor">)
      io << %(<div class="autocomplete__input input flex flex-wrap position-relative flex-item-grow" )
      io << %(data-controller="autocomplete" data-autocomplete-url-value="/autocompletable/users">)
      io << %(<select name="user_ids[]" data-autocomplete-target="select" )
      io << %(data-template-id="autocompletable-user" multiple hidden required></select>)
      io << %(<template id="autocompletable-user">)
      io << %(<div class="autocomplete__pill max-width" data-value="" tabindex="0">)
      io << %(<img class="avatar flex-item-no-shrink" data-content="avatar" src="">)
      io << %(<span class="autocomplete-field__selected-value-text overflow-ellipsis flex-item-grow" )
      io << %(data-content="label"></span>)
      io << %(<button type="button" data-action="autocomplete#remove:prevent" data-value="" )
      io << %(tabindex="-1" class="btn btn--plain txt-small translucent flex-item-no-shrink">)
      io << %(<img src="/assets/remove-circle-384c618c.svg" aria-hidden="true" class="colorize--black">)
      io << %(<span class="for-screen-reader">Remove <span data-content="screenReaderLabel">)
      io << %(</span></span></button></div></template>\n)
      io << %(<input autocomplete="off" autocorrect="off" data-1p-ignore="true" )
      io << %(class="autocomplete__input input flex flex-wrap position-relative" )
      io << %(data-autocomplete-target="input" )
      io << %(data-action="input->autocomplete#search keydown->autocomplete#didPressKey" )
      io << %(type="text" name="rooms_direct[user_ids_input]" id="rooms_direct_user_ids_input">)
      io << %(</div></section>\n)
      io << %(<button name="button" type="submit" class="btn btn--reversed flex-item-no-shrink">)
      io << ChatLayout.icon("check.svg")
      io << %(<span class="for-screen-reader">Start Ping</span></button>)
      io << %(</form>)
      io << %(<span class="txt-small translucent pad-inline-half center">Type names to ping someone…</span>)
      io << %(</div></turbo-frame>\n)
      io << %(</body>\n</html>\n)
    end)
  end

  # POST /rooms/directs — существующая комната с тем же набором участников
  # или новая Rooms::Direct (name NULL, involvement "everything").
  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    ids = selected_user_ids.unshift(user.id.not_nil!).uniq!
    ids.reject! { |id| User.where("id = ? AND status = 0", id).take.nil? }

    room = find_existing_direct(ids)
    unless room
      now = Time.utc
      room = Rooms::Direct.new(creator_id: user.id.not_nil!,
        created_at: now, updated_at: now)
      room.save!
      ids.each do |member_id|
        Membership.new(room_id: room.id.not_nil!, user_id: member_id,
          involvement: "everything", connections: 0,
          created_at: now, updated_at: now).save!
      end
      broadcast_direct_link(room)
    end
    redirect_to "/rooms/#{room.id}"
  end

  # Форма шлёт повторяющиеся user_ids[]: парсер кладёт их в
  # params["user_ids"] (Scalar при одном значении, Array — при
  # нескольких); user_ids[] ключ тоже поддерживаем.
  private def selected_user_ids : Array(Int64)
    ids = [] of Int64
    add = ->(v : String) do
      if (parsed = v.to_i64?)
        ids << parsed
      end
    end
    case value = params["user_ids"]? || params["user_ids[]"]?
    when ActionController::Parameters::Scalar then add.call(value.to_s)
    when Array
      value.each { |v| add.call(v.to_s) }
    when ActionController::Parameters
      value.parameters.each_value do |v|
        case v
        when ActionController::Parameters::Scalar then add.call(v.to_s)
        when Array then v.each { |e| add.call(e.to_s) }
        end
      end
    end
    ids
  end

  # Как routes.js: GROUP BY room HAVING COUNT=? AND SUM(user_id IN ...)=?
  # (STI-порт хранит type коротким именем — "Direct"). ids — только
  # Int64 (из to_i64?), интерполяция безопасна.
  private def find_existing_direct(ids : Array(Int64)) : Room?
    id_list = ids.join(", ")
    Room.where(
      %(id IN (SELECT m.room_id FROM memberships m JOIN rooms r ON r.id = m.room_id
        WHERE r.type = 'Direct'
        GROUP BY m.room_id HAVING COUNT(*) = #{ids.size} AND SUM(m.user_id IN (#{id_list})) = #{ids.size}))).take
  end

  # turbo-stream prepend в #direct_rooms стримов участников
  # (registerRoomForms: gid://campfire/User/<id> base64 + ":rooms").
  private def broadcast_direct_link(room : Room) : Nil
    members = User.where(
      %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)), room.id.not_nil!)
    link = String.build do |io|
      io << %(<a class="direct" id="list_rooms_direct_#{room.id}" )
      io << %(data-room-id="#{room.id}" href="/rooms/#{room.id}">)
      io << %(<span class="direct__author flex align-center gap max-width min-width border-radius txt-small">)
      io << %(<span class="txt-nowrap overflow-ellipsis"><span class="for-screen-reader">Ping with</span>)
      io << %(</span></span></a>)
    end
    stream_html = %(<turbo-stream action="prepend" target="direct_rooms"><template>)
    stream_html += link
    stream_html += %(</template></turbo-stream>)
    members.each do |member|
      Campfire.broadcast(
        Turbo::Streams::StreamName.stream_name_from([member, "rooms"]),
        stream_html)
    end
  end
end

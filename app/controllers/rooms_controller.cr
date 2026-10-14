# GET /rooms/:id — страница комнаты (контракт: полная HTML-страница,
# data-message-id ровно 40 последних сообщений ASC; DOM-идентичности
# id="message_<cmid>" / data-client-message-id="<cmid>"; браузерный гейт:
# message-area + composer + turbo-cable-stream-source + importmap).
# Whole-page response cache (Фаза 3): готовый HTML кэшируется per-worker,
# инвалидация по DB-epoch (PRAGMA data_version); отдача с gzip + ETag/304.
class RoomsController < ApplicationController
  def show
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!
    user = current_user.not_nil!

    epoch = db_epoch # мемо: require_authentication уже вычислил PRAGMA
    key = PageCache.key("rooms#show", request, user.id)
    if (cached = PageCache.get(key, epoch))
      return send_page(cached)
    end

    # Контракт: 40 последних по created_at DESC, вывод в ASC.
    messages = Message.where("room_id = ?", room.id.not_nil!)
      .order("created_at DESC").limit(40).to_a.reverse

    messages_html = String.build do |io|
      messages.each do |m|
        io << ChatLayout.message_dom(m, room, User.find?(m.creator_id.not_nil!))
      end
    end

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    html = String.build do |io|
      io << ChatLayout.head(room.name.to_s, user, room.id, chat: true)
      io << ChatLayout.body_open(room, user)
      io << ChatLayout.message_area(room, messages_html, user)
      io << ChatLayout.composer(room)
      io << ChatLayout.body_close(chat: true)
    end
    page = Campfire::PageCache::Page.new(html)
    # Кэшируем только если БД не менялась за время рендера и ответ чист
    # (200, без Set-Cookie) — иначе старые чтения получат новый epoch.
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    send_page(page)
  end

  # GET /rooms/:id/refresh — опрос refresh-room-контроллера (видимость
  # вкладки/онлайн). Полный_REFRESH_протокол (turbo-stream с пропущенными
  # сообщениями) — Фаза 2 далее; пока честный пустой ответ.
  def refresh
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    render(plain: "", status: 200)
  end

  # GET /rooms/:kind/new — форма новой комнаты (room_form.eta; smoke
  # использует только opens: label "Name this room" + кнопка "Save").
  def new
    user = current_user.not_nil!
    kind = params["kind"].to_s
    return head(:not_found) unless {"opens", "closeds", "directs"}.includes?(kind)
    render(html: String.build { |io| room_form(io, nil, kind, user) })
  end

  # GET /rooms/:room_id/edit — настройки комнаты (ссылка "Settings for
  # this room"): та же форма с текущим именем, _method=patch.
  def edit
    user = current_user.not_nil!
    room = Room.find?(params["room_id"].to_s.to_i64)
    return head(:not_found) unless room
    kind = (room.type.to_s.split("::").last? || "").downcase + "s"
    render(html: String.build { |io| room_form(io, room, kind, user) })
  end

  # POST /rooms/:kind — создание (registerRoomForms): opens дают
  # membership всем активным юзерам; broadcast prepend ссылки в
  # shared_rooms стрима "rooms"; redirect на /rooms/<id>.
  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    kind = params["kind"].to_s
    return head(:not_found) unless kind == "opens"

    name = params["room"]?.try { |r| r.is_a?(ActionController::Parameters) ? r["name"]?.to_s : "" }.to_s
    now = Time.utc
    room = Rooms::Open.new(
      name: name,
      creator_id: user.id.not_nil!,
      created_at: now, updated_at: now)
    room.save!

    User.where("status = 0").each do |member|
      Membership.new(room_id: room.id.not_nil!, user_id: member.id.not_nil!,
        involvement: "member", connections: 0,
        created_at: now, updated_at: now).save!
    end

    broadcast_sidebar_link(room)
    redirect_to "/rooms/#{room.id}"
  end

  # PATCH /rooms/:room_id/edit — переименование (rename): broadcast
  # prepend с тем же id — Turbo дедуплицирует и перемещает ссылку.
  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    room = Room.find(params["room_id"].to_s.to_i64)
    return head(:not_found) unless room
    nested = params["room"]?
    if nested.is_a?(ActionController::Parameters) && (name = nested["name"]?)
      room.name = name.to_s
    end
    room.updated_at = Time.utc
    room.save!
    broadcast_sidebar_link(room)
    redirect_to "/rooms/#{room.id}"
  end

  private def room_form(io, room : Room?, kind : String, user : User) : Nil
    io << ChatLayout.head(room ? "Edit room" : "New room", user, nil, chat: false)
    io << %(<body>\n<main id="main-content">\n)
    io << %(<section class="panel txt-align-center">)
    action = room ? "/rooms/#{room.id}/edit" : "/rooms/#{kind}"
    io << %(<form method="post" action=") << action << %(" accept-charset="UTF-8">)
    io << %(<input type="hidden" name="_method" value="patch">) if room
    io << %(<div class="flex align-center gap">)
    io << %(<label class="flex-item-grow txt-large"><input name="room[name]" id="room_name" )
    io << %(class="input full-width" required autofocus placeholder="Name the room" )
    io << %(data-turbo-permanent="true" type="text" value=")
    io << HTML.escape(room.try(&.name).to_s) << %(">)
    io << %(<span class="for-screen-reader">Name this room</span></label></div>\n)
    io << %(<button name="button" type="submit" class="btn btn--reversed txt-large center">)
    io << %(<span class="for-screen-reader">Save</span></button>\n)
    io << %(</form></section>\n</main>\n</body>\n</html>\n)
  end

  # turbo-stream prepend ссылки комнаты в #shared_rooms (registerRoomForms:
  # publish в стрим "rooms" для opens). id list_rooms_<kind>_<id> — как
  # DOM("list") референса, чтобы Turbo дедуплицировал при переименовании.
  private def broadcast_sidebar_link(room : Room) : Nil
    kind = room.type.to_s.split("::").last?.try(&.downcase)
    link = String.build do |io|
      io << %(<a class="align-center gap room btn txt-nowrap" data-sorted-list-target="item" )
      io << %(data-room-id=") << room.id.not_nil!.to_s
      io << %(" data-sorted-list-name=") << HTML.escape(room.name.to_s)
      io << %(" id="list_rooms_) << kind << "_" << room.id.not_nil!.to_s
      io << %(" style="--column-gap: 0.5em" href="/rooms/) << room.id.not_nil!.to_s << %(">)
      io << %(<span class="overflow-ellipsis">) << HTML.escape(room.name.to_s) << %(</span></a>)
    end
    stream_html = %(<turbo-stream action="prepend" target="shared_rooms"><template>)
    stream_html += link
    stream_html += %(</template></turbo-stream>)
    Campfire.broadcast(
      Turbo::Streams::StreamName.stream_name_from(["rooms"]),
      stream_html)
  end
end

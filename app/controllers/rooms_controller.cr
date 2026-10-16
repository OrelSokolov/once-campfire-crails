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

    # Контракт: 40 последних по created_at DESC, вывод в ASC. Deep-link
    # /rooms/:id/@:message_id — page_around (pagination.rb): 40 до якоря
    # + якорь + 40 после (first_page), вывод ASC.
    messages = if (mid = params["message_id"]?.try(&.to_s).try(&.to_i64?)) &&
                   (anchor = Message.where("room_id = ? AND id = ?",
                     room.id.not_nil!, mid).first?)
      before = Message.where(
        "room_id = ? AND created_at < ?", room.id.not_nil!, anchor.created_at.not_nil!)
        .order("created_at DESC").limit(40).to_a.reverse
      after = Message.where(
        "room_id = ? AND created_at > ?", room.id.not_nil!, anchor.created_at.not_nil!)
        .order("created_at ASC").limit(40).to_a
      before + [anchor] + after
    else
      Message.where("room_id = ?", room.id.not_nil!)
        .order("created_at DESC").limit(40).to_a.reverse
    end

    messages_html = ChatLayout.messages_html(messages, epoch, room, origin)

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    html = String.build do |io|
      io << ChatLayout.head(room.name.to_s, user, room.id, chat: true)
      io << ChatLayout.body_open(room, user)
      io << ChatLayout.message_area(room, messages_html, user, base_url: origin)
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

  # GET /rooms/:kind/new — форма новой комнаты (room_form.eta: имя,
  # список доступа с аватарами/свитчами, фильтр, save с иконкой,
  # delete-панель; directs — direct_new/direct_edit).
  def new
    user = current_user.not_nil!
    kind = params["kind"].to_s
    return head(:not_found) unless {"opens", "closeds", "directs"}.includes?(kind)
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build { |io| room_form(io, nil, kind, user) })
  end

  # GET /rooms/:room_id/edit — настройки комнаты (ссылка "Settings for
  # this room"): та же форма с текущим именем, _method=patch.
  def edit
    user = current_user.not_nil!
    room = Room.find?(params["room_id"].to_s.to_i64)
    return head(:not_found) unless room
    kind = (room.type.to_s.split("::").last? || "").downcase + "s"
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build { |io| room_form(io, room, kind, user) })
  end

  # POST /rooms/:kind — создание (registerRoomForms): opens дают
  # membership всем активным юзерам; closeds — выбранным user_ids[];
  # broadcast prepend ссылки в shared_rooms стрима "rooms"; redirect
  # на /rooms/<id>.
  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    kind = params["kind"].to_s
    return head(:not_found) unless {"opens", "closeds"}.includes?(kind)

    name = params["room"]?.try { |r| r.is_a?(ActionController::Parameters) ? r["name"]?.to_s : "" }.to_s
    now = Time.utc
    room = (kind == "opens" ? Rooms::Open : Rooms::Closed).new(
      name: name,
      creator_id: user.id.not_nil!,
      created_at: now, updated_at: now)
    room.save!

    member_ids = if kind == "opens"
      User.where("status = 0").map(&.id.not_nil!)
    else
      selected_user_ids.unshift(user.id.not_nil!).uniq!
    end
    member_ids.each do |uid|
      Membership.new(room_id: room.id.not_nil!, user_id: uid,
        involvement: "everything", connections: 0,
        created_at: now, updated_at: now).save!
    end

    broadcast_sidebar_link(room)
    redirect_to "/rooms/#{room.id}"
  end

  # PATCH /rooms/:room_id/edit — переименование + sync memberships по
  # user_ids[] (closeds), broadcast prepend с тем же id — Turbo
  # дедуплицирует и перемещает ссылку.
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

    unless room.type.to_s.ends_with?("Open")
      wanted = selected_user_ids.unshift(room.creator_id.not_nil!).uniq!.to_set
      existing = Membership.where("room_id = ?", room.id.not_nil!)
      existing.each do |m|
        unless wanted.includes?(m.user_id.not_nil!)
          Membership.where("room_id = ? AND user_id = ?",
            room.id.not_nil!, m.user_id.not_nil!).delete_all
        end
      end
      have = existing.map(&.user_id.not_nil!).to_set
      now = Time.utc
      wanted.each do |uid|
        next if have.includes?(uid)
        Membership.new(room_id: room.id.not_nil!, user_id: uid,
          involvement: "everything", connections: 0,
          created_at: now, updated_at: now).save!
      end
    end

    broadcast_sidebar_link(room)
    redirect_to "/rooms/#{room.id}"
  end

  # DELETE /rooms/:id — удаление комнаты (room_form.eta delete-панель).
  def destroy
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    room = Room.find?(params["id"].to_s.to_i64)
    return head(:not_found) unless room
    rid = room.id.not_nil!
    Membership.where("room_id = ?", rid).delete_all
    Message.where("room_id = ?", rid).delete_all
    room.destroy
    redirect_to "/"
  end

  # user_ids[] из формы (формат action_pack: Scalar/Array/Parameters).
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

  # room_form.eta: панель с именем, списком доступа (аватары, свитчи,
  # фильтр), save с иконкой check, delete-панель с trash.
  private def room_form(io, room : Room?, kind : String, user : User) : Nil
    selected = if r = room
      Membership.where("room_id = ?", r.id.not_nil!)
        .map(&.user_id.not_nil!).to_set
    else
      Set(Int64).new.tap { |s| s << user.id.not_nil! }
    end
    is_open = kind == "opens"
    can_administer = room.nil? || user.role == 1 || room.creator_id == user.id
    users = User.where("status = 0").to_a
      .sort_by(&.name.to_s.downcase)
      .sort! { |a, b|
        (selected.includes?(b.id.not_nil!) ? 1 : 0) <=>
        (selected.includes?(a.id.not_nil!) ? 1 : 0)
      }
    divider = selected.size

    io << ChatLayout.page_open("room-form", room ? "Edit room" : "New room", user,
      nav_html: ChatLayout.nav_back(room ? "/rooms/#{room.id.not_nil!}" : "/"))
    vt = room ? "edit-room-#{room.id.not_nil!}" : "new-room"
    io << %(<section class="panel txt-align-center" style="view-transition-name: #{vt}">)
    action = "/rooms/#{kind}#{room ? "/#{room.id.not_nil!}" : ""}"
    io << %(<form method="post" action=") << action << %(" accept-charset="UTF-8">)
    io << %(<input type="hidden" name="_method" value="patch">) if room
    io << %(<div class="flex align-center gap">)
    if can_administer
      io << %(<label class="flex-item-grow txt-large"><input name="room[name]" id="room_name" )
      io << %(class="input full-width" required autofocus placeholder="Name the room" )
      io << %(data-turbo-permanent="true" data-action="keydown.enter->form#submit:prevent" )
      io << %(type="text" value=") << HTML.escape(room.try(&.name).to_s) << %(">)
      io << %(<span class="for-screen-reader">Name this room</span></label>)
    else
      io << %(<h1 class="flex-item-grow txt-x-large">) << HTML.escape(room.try(&.name).to_s) << %(</h1>)
    end
    io << %(</div>\n<hr class="margin-block borderless">\n)
    io << %(<section class="room-access margin-block pad-inline fill-shade border-radius">)
    io << %(<menu class="flex flex-column gap margin-none pad overflow-y constrain-height" )
    io << %(data-controller="filter" data-filter-active-class="filter--active" )
    io << %(data-filter-selected-class="selected">\n)

    # «Everyone»: открытость комнаты (opens ↔ closeds свитчем-ссылкой)
    if can_administer || is_open
      io << %(<li class="flex align-center gap margin-none">)
      io << %(<figure class="avatar flex-item-no-shrink" style="--avatar-border-radius: 0; --avatar-size: 4ch">)
      io << %(<img aria-hidden="true" class="colorize--black" style="background-color: transparent" )
      io << %(src=") << ChatLayout.asset("everyone.svg") << %(">)
      io << %(<span class="for-screen-reader">Everyone</span></figure>)
      io << %(<div class="min-width"><div class="overflow-ellipsis fill-shade"><strong>Everyone</strong></div></div>)
      io << %(<hr class="separator" aria-hidden="true">)
      if can_administer
        other = is_open ? "closeds" : "opens"
        io << %(<a class="btn--faux flex-inline" tabindex="-1" data-turbo-action="replace" )
        io << %(href="/rooms/) << other << (room ? "/#{room.id.not_nil!}/edit" : "/new") << %(">)
        io << %(<label for="room_type" class="switch"><input type="checkbox" id="room_type" )
        io << %(class="switch__input") << (is_open ? " checked" : "") << %(">)
        io << %(<span class="switch__btn round"></span><span class="for-screen-reader">)
        io << (is_open ? "Give only some access to this room" : "Give everyone access to this room")
        io << %(</span></label></a>)
      end
      io << %(</li>\n<hr class="separator full-width" style="--border-style: solid">\n)
    end

    io << %(<input type="search" id="search" autocorrect="off" autocomplete="off" )
    io << %(data-1p-ignore="true" class="input input--transparent full-width" )
    io << %(placeholder="Filter…" data-action="input->filter#filter">\n) if users.size > 20

    io << %(<div data-filter-target="list" contents>)
    users.each_with_index do |member, i|
      mid = member.id.not_nil!
      if divider > 0 && i == divider
        io << %(<hr class="separator full-width" style="--border-style: solid">)
      end
      io << %(<li class="flex align-center gap margin-none" data-value=")
      io << HTML.escape(member.name.to_s.downcase) << %(">)
      io << %(<figure class="avatar flex-item-no-shrink" style="--avatar-size: 4ch">)
      io << %(<a title=") << HTML.escape(member.name.to_s)
      io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/#{mid}">)
      io << %(<img aria-hidden="true" loading="lazy" src="/users/#{mid}/avatar" width="48" height="48"></a></figure>)
      io << %(<div class="min-width"><div class="overflow-ellipsis fill-shade"><strong>)
      io << HTML.escape(member.name.to_s) << %(</strong></div></div>)
      io << %(<hr class="separator" aria-hidden="true">)
      if can_administer
        if is_open || (room.nil? && mid == user.id.not_nil!)
          io << %(<input type="hidden" name="user_ids[]" value="#{mid}">) unless is_open
          io << ChatLayout.icon("check.svg", 20, "colorize--black flex-item-no-shrink")
        else
          io << %(<label class="switch flex-item-no-shrink"><input type="checkbox" )
          io << %(name="user_ids[]" value="#{mid}" class="switch__input")
          io << %( checked) if selected.includes?(mid)
          io << %(><span class="switch__btn round"></span><span class="for-screen-reader">Give )
          io << HTML.escape(member.name.to_s) << %( access to this room</span></label>)
        end
      end
      io << %(</li>\n)
    end
    io << %(</div></menu></section>\n)
    if can_administer
      io << %(<button name="button" type="submit" class="btn btn--reversed txt-large center">)
      io << ChatLayout.icon("check.svg") << %(<span class="for-screen-reader">Save</span></button>\n)
    end
    io << %(</form></section>\n)
    if room && can_administer
      io << %(<section class="panel txt-align-center"><form class="button_to" method="post" )
      io << %(action="/rooms/) << room.id.not_nil! << %("><input type="hidden" name="_method" value="delete">)
      io << %(<button class="btn btn--negative max-width" aria-label="Delete )
      io << HTML.escape(room.name.to_s)
      io << %(" data-turbo-confirm="Are you sure you want to delete this room and all messages in it? This can’t be undone." )
      io << %(type="submit">) << ChatLayout.icon("trash.svg")
      io << %(<span class="overflow-ellipsis">) << HTML.escape(room.name.to_s) << %(</span></button></form></section>\n)
    end
    io << ChatLayout.page_close
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

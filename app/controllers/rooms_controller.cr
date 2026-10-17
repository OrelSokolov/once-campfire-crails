# GET /rooms/:id — страница комнаты (контракт: полная HTML-страница,
# data-message-id ровно 40 последних сообщений ASC; DOM-идентичности
# id="message_<cmid>" / data-client-message-id="<cmid>"; браузерный гейт:
# message-area + composer + turbo-cable-stream-source + importmap).
# Whole-page response cache (Фаза 3): готовый HTML кэшируется per-worker,
# инвалидация по DB-epoch (PRAGMA data_version); отдача с gzip + ETag/304.
class RoomsController < ApplicationController
  include RoomsHelpers

  # Rails rooms/{opens,closeds}_controller.rb: before_action
  # :ensure_permission_to_create_rooms, only: [:new, :create].
  before_action :ensure_permission_to_create_rooms, only: [:new, :create]

  # new.html.erb / edit.html.erb + партиал _form.html.erb (room_form)
  # и direct-ветка edit. Данные формы готовит prepare_room_form.
  @room : Room?
  @kind : String = ""
  @user : User?
  # Геттер для RoomsHelpers#page_open (модуль не видит @user).
  getter user
  @selected : Set(Int64) = Set(Int64).new
  @is_open : Bool = false
  @can_administer : Bool = false
  @users : Array(User) = [] of User
  @divider : Int32 = 0
  @direct : Bool = false
  @direct_title : String = ""
  @direct_members : Array(User) = [] of User

  # HTML-партиал формы комнаты (room_form) — compile_partials:
  # locals — типизированные аргументы скомпилированного метода.
  compile_partials({
    "rooms/_form" => {path: "app/views/rooms/_form.html.erb",
                      locals: {"room" => Room?, "kind" => String,
                               "user" => User, "selected" => Set(Int64),
                               "is_open" => Bool, "can_administer" => Bool,
                               "users" => Array(User), "divider" => Int32}},
  })

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
      io << ChatLayout.body_open(room, user,
        ua: request.headers["User-Agent"]?.to_s, origin: origin)
      io << ChatLayout.message_area(room, messages_html, user, base_url: origin)
      # Композер — content_for :footer референса (rooms/show/_composer).
      io << ChatLayout.page_close(ChatERB.new(room: room, origin: origin).composer.to_s,
        ChatLayout.chat_sidebar_frame)
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

  # GET /rooms/:id/involvement — содержимое turbo-frame колокольчика
  # (rooms/involvements/show.html.erb: button_to PUT со следующим
  # состоянием вовлечённости).
  def involvement
    room = Room.find?(params["id"].to_s.to_i64)
    user = current_user
    unless room && user
      response.status = :not_found
      return render(plain: "Room not found")
    end
    membership = Membership.where(
      "room_id = ? AND user_id = ?", room.id.not_nil!, user.id.not_nil!).take
    return render(plain: "Room not found", status: :not_found) unless membership
    involvement = membership.involvement.to_s.presence || "mentions"
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: ChatERB.new(room: room, involvement: involvement,
      origin: origin).involvement_show.to_s)
  end

  # PUT /rooms/:id/involvement — смена вовлечённости (цикл
  # RoomsHelper#next_involvement_for), редирект на show фрейма.
  def update_involvement
    room = Room.find?(params["id"].to_s.to_i64)
    user = current_user
    unless room && user
      response.status = :not_found
      return render(plain: "Room not found")
    end
    membership = Membership.where(
      "room_id = ? AND user_id = ?", room.id.not_nil!, user.id.not_nil!).take
    return render(plain: "Room not found", status: :not_found) unless membership
    value = params["involvement"].to_s
    if %w[mentions everything nothing invisible].includes?(value)
      membership.update({"involvement" => value})
    end
    redirect_to "/rooms/#{room.id}/involvement"
  end

  # GET /rooms/:kind/new — форма новой комнаты (rooms/new.html.erb +
  # _form.html.erb: имя, список доступа с аватарами/свитчами, фильтр,
  # save с иконкой, delete-панель). Роуты вида /rooms/{opens,closeds}/new
  # даёт resources в routes.cr; kind приходит из defaults.
  def new
    user = current_user.not_nil!
    kind = params["kind"].to_s
    return head(:not_found) unless {"opens", "closeds", "directs"}.includes?(kind)
    prepare_room_form(nil, kind, user)
  end

  # GET /rooms/{opens,closeds}/:room_id/edit и /rooms/directs/:room_id/edit —
  # настройки комнаты (ссылка "Settings for this room"): opens/closeds — та
  # же форма с текущим именем, _method=patch; directs — отдельная страница
  # (edit.html.erb: аватары участников + кнопка Delete Ping).
  def edit
    user = current_user.not_nil!
    room = Room.find?(params["room_id"].to_s.to_i64)
    return head(:not_found) unless room
    @user = user
    @room = room
    if room.type.to_s.ends_with?("Direct")
      @direct = true
      members = User.where(
        %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)),
        room.id.not_nil!).order("id").to_a
      uid = user.id.not_nil!
      others = members.reject { |m| m.id == uid }.map(&.name.to_s)
      @direct_title = ChatLayout.display_sentence(others, user.name.to_s)
      @direct_members = members.size > 1 ? members.reject { |m| m.id == uid } : members
    else
      kind = (room.type.to_s.split("::").last? || "").downcase + "s"
      prepare_room_form(room, kind, user)
    end
  end

  # POST /rooms/{opens,closeds} — создание (registerRoomForms): opens дают
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

  # PATCH /rooms/{opens,closeds}/:room_id — переименование + sync memberships по
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

  # Rails rooms_controller.rb: ensure_permission_to_create_rooms — при
  # включённом restrict_room_creation_to_administrators создание комнат
  # (opens/closeds) доступно только администраторам; directs не ограничены.
  private def ensure_permission_to_create_rooms : Nil
    return if params["kind"].to_s == "directs"
    account = Account.take
    if account.try(&.restrict_room_creation_to_administrators?) &&
       current_user.try(&.role) != 1
      head(:forbidden)
    end
  end

  # user_ids[] из формы (формат action_pack: Scalar/Array/Parameters).
  private def selected_user_ids : Array(Int64)    ids = [] of Int64
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

  # Данные _form.html.erb: выбранные участники, флаги админа/открытости,
  # юзеры (выбранные первыми, потом по имени), позиция разделителя.
  private def prepare_room_form(room : Room?, kind : String, user : User) : Nil
    @room = room
    @kind = kind
    @user = user
    selected = if r = room
      Membership.where("room_id = ?", r.id.not_nil!)
        .map(&.user_id.not_nil!).to_set
    else
      Set(Int64).new.tap { |s| s << user.id.not_nil! }
    end
    @selected = selected
    @is_open = kind == "opens"
    @can_administer = room.nil? || user.role == 1 || room.creator_id == user.id
    @users = User.where("status = 0").to_a
      .sort_by(&.name.to_s.downcase)
      .sort! { |a, b|
        (selected.includes?(b.id.not_nil!) ? 1 : 0) <=>
        (selected.includes?(a.id.not_nil!) ? 1 : 0)
      }
    @divider = selected.size
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

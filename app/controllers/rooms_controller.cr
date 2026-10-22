# Whole-page response cache: готовый HTML кэшируется per-worker,
# инвалидация по DB-epoch (PRAGMA data_version); отдача с gzip + ETag/304
# (show). База для Rooms::Opens/Closeds (new/create/edit/update — в
# подклассах), как в Rails rooms_controller.rb.
class RoomsController < ApplicationController
  include RoomsHelpers

  before_action :set_room, only: [:show, :destroy]
  before_action :ensure_can_administer, only: [:destroy]

  @room : Room?
  @kind : String = ""
  @user : User?
  # Геттер для RoomsHelpers#page_open (модуль не видит @user).
  attr_reader :user
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
  }, dedent: true)

  def show
    user = current_user.not_nil!
    page = cache_page("rooms#show", user.id) { room_page(@room.not_nil!, user, find_messages) }
    # Cookie last_room — на каждом ответе, но ПОСЛЕ решения кэша
    # (Set-Cookie до cache_page не дал бы сохранить страницу в кэш).
    remember_last_room_visited(@room.not_nil!)
    send_page(page)
  end

  # GET /rooms/:id/refresh — turbo-stream опрос refresh-room-контроллера:
  # сообщения, созданные после since, — append в контейнер сообщений;
  # обновлённые (кроме новых) — replace по dom_id. Разметка —
  # refresh_stream (RoomsHelpers).
  def refresh
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!

    # since — мс-эпоха (refresh_room_controller: loaded-at / message
    # updated-at), пустое/невалидное — Time.at(0).
    since = Time.unix_ms(params["since"]?.try(&.to_s.to_i64?) || 0_i64)

    # page_created_since: created_at > since, первая страница (40 ASC).
    new_messages = Message.where(
      "room_id = ? AND created_at > ?", room.id.not_nil!, since)
      .order("created_at ASC").limit(40).to_a

    # page_updated_since + without(new): updated_at > since, последняя
    # страница сортировки по created_at (DESC limit 40 → ASC), минус новые.
    new_ids = Set.new(new_messages.map(&.id.not_nil!))
    updated_messages = Message.where(
      "room_id = ? AND updated_at > ?", room.id.not_nil!, since)
      .order("created_at DESC").limit(40).to_a.reverse
      .reject { |m| new_ids.includes?(m.id.not_nil!) }

    render(html: refresh_stream(room, new_messages, updated_messages),
      content_type: "text/vnd.turbo-stream.html")
  end

  # GET /rooms/:id/involvement — содержимое turbo-frame колокольчика
  # (button_to PUT со следующим состоянием вовлечённости).
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

  # DELETE /rooms/:id — удаление комнаты (room_form.eta delete-панель).
  def destroy
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    room = @room.not_nil!
    rid = room.id.not_nil!
    Membership.where("room_id = ?", rid).delete_all
    Message.where("room_id = ?", rid).delete_all
    room.destroy
    redirect_to root_path
  end

  private def set_room
    room = room_scope.where(id: (params["room_id"]? || params["id"]).to_s.to_i64).first
    if room
      @room = room
    else
      redirect_to root_path, alert: "Room not found or inaccessible"
    end
  end

  # Subclasses narrow this to the room types they're allowed to act on, so that one
  # room namespace can't be used to reach another's rooms.
  def room_scope
    Room.where("id IN (SELECT room_id FROM memberships WHERE user_id = ?)",
      Current.user.not_nil!.id.not_nil!)
  end

  def ensure_can_administer
    head :forbidden unless Current.user.not_nil!.can_administer?(@room)
  end

  # При включённом restrict_room_creation_to_administrators создание
  # комнат (opens/closeds) доступно только администраторам; directs не
  # ограничены (вызывается из подклассов Rooms::Opens/Closeds).
  def ensure_permission_to_create_rooms : Nil
    account = Account.take
    if account.try(&.restrict_room_creation_to_administrators?) &&
       !Current.user.not_nil!.administrator?
      head(:forbidden)
    end
  end

  def room_params
    params.require("room").permit("name")
  end

  # Контракт: 40 последних по created_at DESC, вывод в ASC. Deep-link
  # /rooms/:id/@:message_id — page_around (pagination.rb): 40 до якоря
  # + якорь + 40 после. Сравнение — субзапросом по id (как в
  # messages#index): литеральный Time-бинд sqlite3-шарда сериализуется
  # с миллисекундами, и строка якоря без дроби префиксно меньше её —
  # якорь попадал и в before, и в [anchor], дублируясь в выдаче.
  def find_messages : Array(Message)
    room = @room.not_nil!
    if (mid = params["message_id"]?.try(&.to_s).try(&.to_i64?)) &&
       (anchor = Message.where("room_id = ? AND id = ?",
         room.id.not_nil!, mid).first?)
      before = Message.where(
        "room_id = ? AND created_at < (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, mid)
        .order("created_at DESC").limit(40).to_a.reverse
      after = Message.where(
        "room_id = ? AND created_at > (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, mid)
        .order("created_at ASC").limit(40).to_a
      before + [anchor] + after
    else
      Message.where("room_id = ?", room.id.not_nil!)
        .order("created_at DESC").limit(40).to_a.reverse
    end
  end

  # TrackedRoomVisit: cookies.permanent.
  def remember_last_room_visited(room : Room) : Nil
    cookies.permanent["last_room"] = room.id.not_nil!.to_s
  end

  # Общее create Rooms::Opens/Closeds: комната класса klass + membership
  # member_ids (opens — все активные, closeds — выбранные), broadcast
  # ссылки, redirect на /rooms/<id>.
  def create_room(klass : Rooms::Open.class | Rooms::Closed.class,
                  member_ids : Array(Int64),
                  user : User) : Nil
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    room = klass.new(
      name: room_params["name"]?.to_s,
      creator_id: user.id.not_nil!,
      created_at: Time.utc, updated_at: Time.utc)
    room.save!

    now = Time.utc
    member_ids.each do |uid|
      Membership.new(room_id: room.id.not_nil!, user_id: uid,
        involvement: "everything", connections: 0,
        created_at: now, updated_at: now).save!
    end

    broadcast_sidebar_link(room)
    redirect_to room_path(room.id)
  end

  # Общее update Rooms::Opens/Closeds: переименование + sync memberships по
  # user_ids[] (opens не пересобирают членство — membership у всех), broadcast
  # prepend с тем же id — Turbo дедуплицирует и перемещает ссылку.
  def update_room : Nil
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    room = @room.not_nil!
    if name = room_params["name"]?
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
    redirect_to room_path(room.id)
  end

  # user_ids[] из формы (формат action_pack: Scalar/Array/Parameters).
  def selected_user_ids : Array(Int64)
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

  # Данные _form.html.erb: выбранные участники, флаги админа/открытости,
  # юзеры (выбранные первыми, потом по имени), позиция разделителя.
  def prepare_room_form(room : Room?, kind : String, user : User) : Nil
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
    @users = User.active.to_a.sort_by(&.name.to_s.downcase)
    if @is_open
      # opens-форма: User.active.ordered — просто LOWER(name), без
      # деления на выбранных/остальных (артефакт room-settings).
      @divider = 0
    else
      @users.sort! { |a, b|
        (selected.includes?(b.id.not_nil!) ? 1 : 0) <=>
        (selected.includes?(a.id.not_nil!) ? 1 : 0)
      }
      @divider = selected.size
    end
  end

  # turbo-stream prepend ссылки комнаты в #shared_rooms: ручной аналог
  # партиала _shared (id list_rooms_<kind>_<id> — как DOM("list")
  # референса, чтобы Turbo дедуплицировал при переименовании).
  def broadcast_sidebar_link(room : Room) : Nil
    kind = room.type.to_s.split("::").last?.try(&.downcase)
    link = String.build do |io|
      io << %(<a class="align-center gap room btn txt-nowrap" data-sorted-list-target="item" )
      io << %(data-room-id=") << room.id.not_nil!.to_s
      io << %(" data-sorted-list-name=") << HTML.escape(room.name.to_s)
      io << %(" id="list_rooms_) << kind << "_" << room.id.not_nil!.to_s
      io << %(" style="--column-gap: 0.5em" href="/rooms/) << room.id.not_nil!.to_s << %(">)
      io << %(<span class="overflow-ellipsis">) << HTML.escape(room.name.to_s) << %(</span></a>)
    end
    broadcast_prepend_to(["rooms"], target: "shared_rooms", html: link)
  end
end

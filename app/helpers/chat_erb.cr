# ChatERB — ERB-контекст HTML-шаблонов app/views/** (порт
# once-campfire/app/views + templates/eta express-реализации как эталон
# переносов). Разметка живёт в шаблонах и компилируется на этапе сборки
# (compile_template, как jbuilder-партиалы); хелперы делегируют в ChatLayout.
class ChatERB
  include ERB::Rendering

  def initialize(@room : Room? = nil, @footer : String = "", @sidebar : String = "",
                 @origin : String = "", @involvement : String = "mentions",
                 @ua : String = "",
                 @user : User? = nil,
                 @directs : Array(SidebarDirect) = [] of SidebarDirect,
                 @shared : Array(SidebarShared) = [] of SidebarShared,
                 @placeholders : Array(User) = [] of User,
                 @rooms_stream : String = "", @user_rooms_stream : String = "")
  end

  # rooms/show/_composer.html.erb, rooms/involvements/**
  def room : Room
    @room.not_nil!
  end

  # layouts/_body_close.html.erb (SafeString: HTML без повторного
  # экранирования в <%= %>)
  def footer : ERB::SafeString
    ERB::SafeString.new(@footer)
  end

  # layouts/_body_close.html.erb — строка content_for :sidebar референса
  # (SafeString: HTML без повторного экранирования в <%= %>).
  # Имя НЕ `sidebar`: compile_template "sidebar" ниже определяет метод
  # рендера сайдбар-шаблона и перекрыл бы этот аксессор.
  def sidebar_html : ERB::SafeString
    ERB::SafeString.new(@sidebar)
  end

  # asset("arrow-up.svg") → "/assets/arrow-up-f96b3895.svg" (ChatLayout).
  def asset(name : String) : String
    ChatLayout.asset(name)
  end

  # Lightbox-диалог layout'а (layouts/_lightbox).
  def lightbox : ERB::SafeString
    ERB::SafeString.new(ChatLayout.lightbox_dialog)
  end

  # ————— rooms/involvements (bell + pwa-диалоги + show) —————

  # useragent-классификация для pwa-инструкций (ApplicationPlatform).
  def platform : PlatformAgent
    PlatformAgent.new(@ua)
  end

  # root_url референса (инструкции печатают абсолютный origin).
  def root_url : String
    @origin.empty? ? "/" : "#{@origin}/"
  end

  # rich_text_area (ActionText): абсолютные route-URL —
  # rails_direct_uploads_url и blob-redirect-шаблон.
  def direct_uploads_url : String
    @origin.empty? ? "/rails/active_storage/direct_uploads" : "#{@origin}/rails/active_storage/direct_uploads"
  end

  def blob_url_template : String
    base = @origin.empty? ? "" : @origin
    "#{base}/rails/active_storage/blobs/redirect/:signed_id/:filename"
  end

  def involvement : String
    @involvement
  end

  # direct: everything→nothing; остальные: mentions→everything→nothing→
  # invisible (RoomsHelper#next_involvement_for).
  def next_involvement : String
    choices = room.name.nil? ? %w[everything nothing] : %w[mentions everything nothing invisible]
    idx = choices.index(involvement) || -1
    choices[(idx + 1) % choices.size]
  end

  def human_involvement : String
    ChatLayout::INVOLVEMENT_LABELS[involvement]? || involvement
  end

  # Ping для direct-комнат, иначе room (bell SR-текст).
  def noun : String
    room.name.nil? ? "Ping" : "room"
  end

  # dom_id референса: STI route_key (Rooms::Open → rooms_open).
  def dom_id(prefix : String) : String
    key = room.type.to_s.split("::")
    key = ["rooms", key.last?.to_s.downcase] if key.size > 1
    "#{prefix}_#{key.join("_")}_#{room.id}"
  end

  # ————— users/sidebars/show (сайдбар) —————

  class SidebarDirect
    property room_id : Int64, epoch_ms : Int64, unread : Bool, members : Array(User)

    def initialize(@room_id, @epoch_ms, @unread, @members)
    end
  end

  class SidebarShared
    property room : Room, unread : Bool

    def initialize(@room, @unread)
    end
  end

  def directs : Array(SidebarDirect)
    @directs
  end

  def shared : Array(SidebarShared)
    @shared
  end

  def placeholders : Array(User)
    @placeholders
  end

  def user : User
    @user.not_nil!
  end

  def rooms_stream : String
    @rooms_stream
  end

  def user_rooms_stream : String
    @user_rooms_stream
  end

  # fresh_user_avatar_path (UsersHelper) для аватаров сайдбара.
  def avatar_path(u : User) : String
    ChatLayout.fresh_user_avatar_path(u.id.not_nil!, u.updated_at)
  end

  # Подпись direct-комнаты: одному участнику — первое слово имени,
  # нескольким — инициалы (3 первых слова по букве) через to_sentence
  # (two_words_connector: '+').
  def direct_label(d : SidebarDirect) : String
    if d.members.size > 1
      parts = d.members.map do |m|
        m.name.to_s.split(" ")[0, 3].map { |w| (w[0]? || "").upcase }.join
      end
      case parts.size
      when 2 then parts.join("+")
      else        "#{parts[0..-2].join(", ")}, and #{parts[-1]}"
      end
    else
      d.members.first.name.to_s.split(" ")[0]? || ""
    end
  end

  # dom_id(room, :list) референса: STI route_key (open/direct/closed).
  def route_key(room : Room) : String
    key = room.type.to_s.split("::")
    return room.type.to_s.downcase if key.size == 1
    key.join("_").downcase
  end

  def new_room_allowed? : Bool
    user.role == 1
  end

  compile_template "sidebar", "app/views/users/sidebars/show.html.erb"

  compile_template "composer", "app/views/rooms/show/_composer.html.erb"
  compile_template "body_close", "app/views/layouts/_body_close.html.erb"
  compile_template "bell", "app/views/rooms/involvements/_bell.html.erb"
  compile_template "involvement_show", "app/views/rooms/involvements/show.html.erb"

  # Вложенные партиалы — через render(): compile_template-методы
  # переключают общий @__erb_buf, вложенный вызов затёр бы буфер
  # родителя; партиалы честно подменяют его и восстанавливают.
  compile_partials({
    "browser_settings"     => {path: "app/views/rooms/involvements/_browser_settings.html.erb", locals: {} of String => Nil},
    "system_settings"      => {path: "app/views/rooms/involvements/_system_settings.html.erb", locals: {} of String => Nil},
    "install_instructions" => {path: "app/views/rooms/involvements/_install_instructions.html.erb", locals: {} of String => Nil},
  })
end

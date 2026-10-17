# GET/PATCH /account(/edit) — настройки аккаунта (референс:
# accounts/edit.html.erb + account.eta): имя, настройка создания
# комнат, invite-ссылка. Только администратор (role=1).
# Файл идёт первым по алфавиту в app/controllers/** — ApplicationController
# нужно потребовать явно.
require "./application_controller"

class AccountsController < ApplicationController
  # edit.html.erb: аккаунт, viewer (ветка admin/non-admin), состояние
  # restrict-свитча, invite-ссылка + QR-путь, юзеры аккаунта.
  @account : Account?
  @user : User?
  @restrict : Bool = false
  @join_url : String = ""
  @qr_path : String = ""
  @users : Array(User) = [] of User

  def edit
    @account = Account.take.not_nil!
    user = current_user.not_nil!
    @user = user
    # restrict_room_creation_to_administrators (settings JSON)
    @restrict = @account.not_nil!.settings.to_s
      .includes?(%("restrict_room_creation_to_administrators":true))
    @join_url = origin + "/join/" + @account.not_nil!.join_code.to_s
    @qr_path = "/qr_code/" + Base64.urlsafe_encode(@join_url, padding: false)
    @users = User.where("status = 0").order("id").to_a
  end

  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    return render(plain: "forbidden", status: 403) unless user.role == 1
    account = Account.take.not_nil!
    account.name = nested("name") unless nested?("name").nil?
    # restrict_room_creation_to_administrators (settings JSON, PUT-свитч)
    settings = params["account"]?
    if settings.is_a?(ActionController::Parameters) &&
       (nest = settings["settings"]?).is_a?(ActionController::Parameters) &&
       (restrict = nest["restrict_room_creation_to_administrators"]?)
      value = restrict.to_s == "true"
      existing = account.settings.try(&.to_json).presence
      new_json = if existing.nil? || existing == "{}"
        %({"restrict_room_creation_to_administrators":#{value}})
      elsif existing.includes?("restrict_room_creation_to_administrators")
        existing.gsub(/"restrict_room_creation_to_administrators"\s*:\s*(true|false)/,
          %("restrict_room_creation_to_administrators":#{value}))
      else
        existing.sub(%r(\s*\}\s*\z), %(", "restrict_room_creation_to_administrators":#{value}}))
      end
      account.settings = JSON::Any.from_json(new_json)
    end
    account.updated_at = Time.utc
    account.save!
    redirect_to "/account/edit"
  end

  # ————— ERB-хелперы (app/views/accounts/edit.html.erb) —————
  # SafeString: сырой HTML из ChatLayout без повторного экранирования
  # в <%= %> (как boosts/profiles).

  # head + body + nav аккаунта (боты/кастомные стили для админа) + main.
  private def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("account", "Account settings", user,
      nav_html: account_nav(user)))
  end

  # layouts/_body_close + версия в футере (Campfire™ version badge).
  private def page_close : ERB::SafeString
    version = HTML.escape(ENV["APP_VERSION"]? || "parity")
    footer = %(<div class="txt-align-center center margin-block-double txt-subtle">Campfire&trade; version <span class="version-badge">) +
      version + %(</span></div>)
    ERB::SafeString.new(ChatLayout.page_close(footer))
  end

  private def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  private def copy_button(url : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.copy_button(url, "Copy join link"))
  end

  # Логотип аккаунта (logos/app-icon.png, fingerprinted asset).
  private def app_logo_src : String
    ChatLayout.asset("logos/app-icon.png")
  end

  # account_nav.eta: назад + ссылки на ботов/кастомные стили (админ).
  private def account_nav(user : User) : String
    String.build do |io|
      io << ChatLayout.nav_back("/")
      if user.role == 1
        io << %(<div class="flex align-center gap flex-item-justify-end">)
        io << %(<a href="/account/bots" class="btn" style="view-transition-name: chat-bots">)
        io << ChatLayout.icon("bot.svg") << %(<span class="for-screen-reader">Set up chat bots</span></a>)
        io << %(<a href="/account/custom_styles/edit" class="btn" style="view-transition-name: custom-styles">)
        io << ChatLayout.icon("art.svg") << %(<span class="for-screen-reader">Custom styles</span></a>)
        io << %(</div>)
      end
    end
  end

  private def nested?(key : String) : String?
    nested = params["account"]?
    return nil unless nested.is_a?(ActionController::Parameters)
    value = nested[key]?
    value.nil? ? nil : value.to_s
  end

  private def nested(key : String) : String
    nested?(key).to_s
  end
end

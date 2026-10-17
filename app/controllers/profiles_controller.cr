# GET/PATCH /users/me/profile — профиль текущего пользователя
# (референс: users/profiles/show.html.erb + profile.eta): форма
# name/email/password/bio, список комнат участия и session
# transfer-ссылка с QR (4 часа действия, purpose "user/transfer").
# Разметка — app/views/profiles/show.html.erb (implicit render),
# контроллер готовит данные.
class ProfilesController < ApplicationController
  # show.html.erb: user, пары комната-membership для списка участия,
  # transfer-ссылка и QR-путь к ней.
  @user : User?
  @room_memberships : Array(Tuple(Room, Membership)) = [] of Tuple(Room, Membership)
  @transfer_url : String = ""
  @qr_path : String = ""

  def show
    user = current_user.not_nil!
    @user = user
    rooms = Room.where(
      %(id IN (SELECT room_id FROM memberships WHERE user_id = ?)), user.id.not_nil!)
      .to_a.index_by(&.id.not_nil!)
    user.memberships.each do |membership|
      if room = rooms[membership.room_id.not_nil!]?
        @room_memberships << {room, membership}
      end
    end
    @transfer_url = transfer_url_for(user)
    @qr_path = "/qr_code/" + Base64.urlsafe_encode(@transfer_url, padding: false)
  end

  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    user.name = nested("name") unless nested?("name").nil?
    user.email_address = nested("email_address") unless nested?("email_address").nil?
    user.bio = nested("bio") unless nested?("bio").nil?
    password = nested?("password").to_s
    unless password.empty?
      user.password_digest = Crypto::Bcrypt::Password.create(password, cost: 10).to_s
    end
    user.updated_at = Time.utc
    user.save!
    redirect_to "/users/me/profile"
  end

  # ————— ERB-хелперы (app/views/profiles/show.html.erb) —————
  # SafeString: сырой HTML из ChatLayout без повторного экранирования
  # в <%= %> (как boosts).

  # head + body + nav профиля (back + logout) + main (ChatLayout.page_open).
  private def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("profile", "Profile: #{user.name}", user,
      nav_html: profile_nav))
  end

  private def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close)
  end

  private def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  private def copy_button(url : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.copy_button(url, "Copy auto-login link"))
  end

  # involvement.eta (статически, без involvement-роута).
  private def involvement_chip(room : Room, membership : Membership) : ERB::SafeString
    involvement = membership.involvement.to_s.presence || "mentions"
    human = ChatLayout::INVOLVEMENT_LABELS[involvement]? || involvement
    ERB::SafeString.new(
      %(<turbo-frame id="involvement_room_#{room.id.not_nil!}">) +
      %(<button role="checkbox" aria-checked="true" tabindex="0" class="btn #{involvement}" type="button">) +
      ChatLayout.icon("notification-bell-#{involvement}.svg") +
      %(<span class="for-screen-reader">) + human + %(</span></button></turbo-frame>))
  end

  # profile_nav.eta: назад + logout (кнопка-иконка, форма на /session).
  private def profile_nav : String
    String.build do |io|
      io << ChatLayout.nav_back("/")
      io << %(<div class="flex-item-justify-end"><form method="post" action="/session">)
      io << %(<input type="hidden" name="_method" value="delete">)
      io << %(<button class="btn">) << ChatLayout.icon("logout.svg")
      io << %(<span class="for-screen-reader">Log out</span></button></form></div>)
    end
  end

  # 4 часа действия, как в референсе (routes.js: 4 * 3600000).
  private def transfer_url_for(user : User) : String
    origin + "/session/transfers/" +
      generate_signed_id(user.id.not_nil!, "user/transfer",
        expires_at: Time.utc + 4.hours)
  end

  private def nested?(key : String) : String?
    nested = params["user"]?
    return nil unless nested.is_a?(ActionController::Parameters)
    value = nested[key]?
    value.nil? ? nil : value.to_s
  end

  private def nested(key : String) : String
    nested?(key).to_s
  end
end

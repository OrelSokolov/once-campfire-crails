# GET/PATCH /users/me/profile — профиль текущего пользователя
# (референс: users/profiles/show.html.erb + profile.eta): форма
# name/email/password/bio, список комнат участия и session
# transfer-ссылка с QR (4 часа действия, purpose "user/transfer").
# Разметка — app/views/users/profiles/show.html.erb (implicit render),
# контроллер готовит данные.
class Users::ProfilesController < ApplicationController
  include ProfilesHelpers

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

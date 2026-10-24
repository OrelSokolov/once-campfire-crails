class Users::ProfilesController < ApplicationController
  include Users::ProfilesHelper

  @user : User?
  @shared_memberships : Array(Tuple(Room, Membership)) = [] of Tuple(Room, Membership)
  @direct_memberships : Array(Tuple(Room, Membership)) = [] of Tuple(Room, Membership)
  @ua : String = ""
  @transfer_url : String = ""
  @qr_path : String = ""

  def show
    user = current_user.not_nil!
    @user = user
    @ua = request.headers["User-Agent"]?.to_s
    rooms = Room.where(
      %(id IN (SELECT room_id FROM memberships WHERE user_id = ?)), user.id.not_nil!)
      .to_a.index_by(&.id.not_nil!)
    user.memberships.each do |membership|
      next unless room = rooms[membership.room_id.not_nil!]?
      if room.direct?
        @direct_memberships << {room, membership}
      else
        @shared_memberships << {room, membership}
      end
    end
    @shared_memberships.sort_by! { |(room, _)| room.name.to_s.downcase }
    @direct_memberships.sort_by! { |(room, _)| room.id.not_nil! }
    @transfer_url = transfer_url_for(user)
    @qr_path = "/qr_code/" + Base64.urlsafe_encode(@transfer_url, padding: false)
  end

  def update
    Campfire::ResponseCache.invalidate!
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
    redirect_to user_profile_url
  end

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

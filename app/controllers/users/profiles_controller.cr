class Users::ProfilesController < ApplicationController

  @user : User?
  @shared_memberships : Array(Users::ProfilesHelper::MembershipEntry) = [] of Users::ProfilesHelper::MembershipEntry
  @direct_memberships : Array(Users::ProfilesHelper::MembershipEntry) = [] of Users::ProfilesHelper::MembershipEntry
  @ua : String = ""
  @transfer_url : String = ""
  @qr_path : String = ""

  # Oracle users/profiles/show.html.erb renders the _membership partial
  # collection twice (shared + direct rooms); the nav comes from the
  # content_for :nav block (_nav partial).
  compile_partials({
    "users/profiles/membership" => {path: "app/views/users/profiles/_membership.html.erb",
                                     locals: {"membership" => Users::ProfilesHelper::MembershipEntry}},
    "users/profiles/nav"        => {path: "app/views/users/profiles/_nav.html.erb",
                                     locals: {} of String => Nil},
  }, dedent: true)

  def show
    user = current_user!
    @user = user
    @ua = request.headers["User-Agent"]?.to_s
    rooms = Room.where(
      %(id IN (SELECT room_id FROM memberships WHERE user_id = ?)), user.id!)
      .to_a.index_by(&.id!)
    user.memberships.each do |membership|
      next unless room = rooms[membership.room_id!]?
      entry = Users::ProfilesHelper::MembershipEntry.new(room, membership)
      if room.direct?
        @direct_memberships << entry
      else
        @shared_memberships << entry
      end
    end
    @shared_memberships.sort_by! { |entry| entry.room.name.to_s.downcase }
    @direct_memberships.sort_by! { |entry| entry.room.id! }
    @transfer_url = transfer_url_for(user)
    @qr_path = "/qr_code/" + Base64.urlsafe_encode(@transfer_url, padding: false)
  end

  def update
    user = current_user!
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
      generate_signed_id(user.id!, "user/transfer",
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

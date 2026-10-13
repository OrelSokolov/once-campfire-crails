class User < ActiveRecord::Base
  has_many :memberships, foreign_key: "user_id"
  has_many :sessions, foreign_key: "user_id"
  has_many :messages, foreign_key: "creator_id"
  has_many :searches, foreign_key: "user_id", class_name: "Search"

  # Rails: User.active.authenticate_by(email_address:, password:) —
  # bcrypt compare against password_digest (status 0 = active).
  def self.authenticate(email_address : String, password : String) : User?
    user = where("email_address = ? AND status = 0", email_address).take
    return nil unless user
    digest = user.password_digest.to_s
    return nil if digest.empty?
    begin
      bcrypt = Crypto::Bcrypt::Password.new(digest)
    rescue Crypto::Bcrypt::Error
      return nil
    end
    bcrypt.verify(password) ? user : nil
  end

  def avatar_blob : ActiveStorageBlob?
    ActiveStorageAttachment
      .where("record_type = ? AND record_id = ? AND name = ?", "User", id.not_nil!, "avatar")
      .take.try do |attachment|
      ActiveStorageBlob.find(attachment.blob_id.not_nil!)
    end
  end
end

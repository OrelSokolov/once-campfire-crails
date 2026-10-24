require "./application_record"
class Room < ApplicationRecord
  has_many :memberships, foreign_key: "room_id"
  has_many :messages, foreign_key: "room_id"
  belongs_to :creator, class_name: "User"

  # STI type is stored in two spellings ('Rooms::Open' from seeds, short 'Open' created by the port), so scope to IN of both.
  scope(:opens)           { where("type IN ('Open', 'Rooms::Open')") }
  scope(:closeds)         { where("type IN ('Closed', 'Rooms::Closed')") }
  scope(:directs)         { where("type IN ('Direct', 'Rooms::Direct')") }
  scope(:without_directs) { where("type NOT IN ('Direct', 'Rooms::Direct')") }
  scope(:ordered)         { order("LOWER(name)") }

  # gid is built from the record's STI class, not Crystal's Room, to keep turbo-cable-stream-source signed names matching.
  def to_gid_param : String
    sti = type.to_s
    sti = "Rooms::#{sti}" unless sti.includes?("::")
    gid = "gid://#{Turbo.app}/#{sti}/#{id.not_nil!}"
    Base64.urlsafe_encode(gid, padding: false)
  end

  def dom_id : String
    sti = type.to_s.split("::")[-1].underscore
    "rooms_#{sti}_#{id.not_nil!}"
  end

  # Direct rooms have name IS NULL; detected by name, not type, since type is stored in two spellings.
  def direct? : Bool
    name.nil?
  end

  # Visible rooms for a user, involvement-filtered (sidebar listing).
  scope(:visible, ->(user) {
    where(%(id IN (SELECT room_id FROM memberships WHERE user_id = ? AND involvement != 'invisible')),
      user.id.not_nil!)
  })

  def self.visible_for(user : User)
    visible(user)
  end

  # Takes the room away from its members at once, and leaves its messages to Room::DestroyJob. Destroying them in
  # the room's own transaction held the database's write lock, and stopped every other write, until the last one.
  # An open room is closed first, so that no one who joins the account before the job runs is let in.
  def destroy_later : Nil
    Campfire::ResponseCache.invalidate!
    rid = id.not_nil!
    now = Time.utc
    former_member_ids = Campfire::WriteQueue.perform do
      ActiveRecord::Base.transaction do
        conn = ActiveRecord::Base.__session
        conn.exec("UPDATE rooms SET type = 'Closed', updated_at = ? WHERE id = ?", now, rid)
        ids = conn.query_all(
          "SELECT user_id FROM memberships WHERE room_id = ?", rid) do |rs|
          rs.read(Int64)
        end
        conn.exec("DELETE FROM memberships WHERE room_id = ?", rid)
        ids
      end
    end || [] of Int64
    Campfire::JobQueue.enqueue_batch([{"room_destroy", %({"room_id":#{rid},"former_member_ids":[#{former_member_ids.join(",")}]})}])
  end
end

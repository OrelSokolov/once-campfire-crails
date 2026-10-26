require "./application_record"
class Room < ApplicationRecord
  has_many :memberships, foreign_key: "room_id"
  has_many :users, through: :memberships
  has_many :messages, foreign_key: "room_id", dependent: :destroy
  belongs_to :creator, class_name: "User", default: -> { Current.user }

  # STI type: where(type:) on a namespaced value matches both spellings
  # ('Rooms::Open' from reference seeds, short 'Open' created by the port) —
  # the IN-expansion lives in active_record_cr Relation#where.
  scope(:opens)           { where(type: "Rooms::Open") }
  scope(:closeds)         { where(type: "Rooms::Closed") }
  scope(:directs)         { where(type: "Rooms::Direct") }
  scope(:without_directs) { where.not(type: "Rooms::Direct") }
  scope(:ordered)         { order("LOWER(name)") }

  # gid is built from the record's STI class, not Crystal's Room, to keep turbo-cable-stream-source signed names matching.
  def gid_model_name : String
    sti = type.to_s
    sti = "Rooms::#{sti}" unless sti.includes?("::")
    sti
  end

  # form_with model: — the scope and the polymorphic route key are the STI
  # model name (Rooms::Open → rooms_open), normalized like dom_id for both
  # type spellings (short 'Open' and seed 'Rooms::Open' on a base-class row).
  def form_scope : String
    gid_model_name.underscore.tr("/", "_")
  end

  def form_model_name : String
    form_scope
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
      user.id!)
  })

  def self.visible_for(user : User)
    visible(user)
  end

  # oracle Room.create_for: create! + memberships.grant_to(users) in one
  # transaction; Rooms::Open additionally grants every active user in
  # after_save_commit (rooms/open.cr), so the insert is conflict-safe.
  def self.create_for(attributes : Hash(String, ActiveRecord::Value),
                      users : Array(Int64)) : self
    room = new
    room.assign_attributes(attributes)
    room.save!
    Membership.grant_to(room, users)
    room
  end

  # The account's original room (the "All Talk" one of the first run).
  def self.original : Room?
    order("created_at").first
  end

  def receive(message : Message) : Nil
    unread_memberships(message)
    push_later(message)
  end

  # Rewriting every member on every message is most of what posting to a large
  # room writes, so members who are unread already stay as they are. Directs
  # keep touching them all: a direct's sidebar row is cached by membership and
  # shows the room's recency.
  def unread_memberships(message : Message) : Nil
    recipients = memberships.visible.disconnected.where.not(user_id: message.creator_id!)
    recipients = recipients.where(unread_at: nil) unless direct?
    recipients.update_all({"unread_at" => message.created_at, "updated_at" => Time.utc})
  end

  # Room::PushMessageJob enqueue tuple — the JobQueue DB write must stay
  # outside the production transaction (see MessageCreator#create!).
  def push_later(message : Message) : Tuple(String, String)
    Room::PushMessageJob.__queue_pair(self, message)
  end

  # Deleting the memberships skips the reset that revoking one does, so the former members get it here, all at once,
  # before the messages go: their connections stop receiving the room's streams. It's done in the job, not the
  # request, because it costs a Redis round trip per member.
  def reset_remote_connections_of(user_ids : Array(Int64)) : Nil
    User.where(id: user_ids).find_each(&.reset_remote_connections)
  end

  # Each message is destroyed in its own transaction, so other writes get through in between. Any message posted
  # meanwhile goes with the room.
  def destroy_one_message_at_a_time : Nil
    messages.find_each(&.destroy)
    destroy
  end

  def open? : Bool
    is_a?(Rooms::Open)
  end

  def closed? : Bool
    is_a?(Rooms::Closed)
  end

  def default_involvement : String
    "mentions"
  end

  # Takes the room away from its members at once, and leaves its messages to Room::DestroyJob. Destroying them in
  # the room's own transaction held the database's write lock, and stopped every other write, until the last one.
  # An open room is closed first, so that no one who joins the account before the job runs is let in.
  def destroy_later : Nil
    # open? ? becomes!(Rooms::Closed) : self — the becomes() class switch
    # must happen BEFORE save!: Rooms::Open's after_save_commit would grant
    # membership to every active user on the way to deletion.
    room = open? ? becomes(Rooms::Closed) : self
    former_member_ids = Campfire::WriteQueue.perform do
      ActiveRecord::Base.transaction do
        room.save!
        ids = room.memberships.pluck(:user_id).map(&.as(Int64))
        room.memberships.delete_all
        ids
      end
    end || [] of Int64
    Room::DestroyJob.perform_later(room, former_member_ids)
  end
end

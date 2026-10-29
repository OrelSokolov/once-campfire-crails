require "json"
require "sqlite3"
require "digest/md5"

# Creates a message with all of the room's side effects (port of MessagesController#create +
# Room#receive + notifyMessage): insert + ActionText body + FTS5 index + turbo-stream broadcast +
# unread_memberships + notification job enqueueing — all persisted before the HTTP response.
module MessageCreator
  alias UploadedFile = Message::Attachment::UploadedFile

  # Returns the created message (after body/index insert and broadcast).
  # attachment: store the file as blob + active_storage_attachments; the FTS index gets body or filename.
  def self.create!(room : Room, creator : User, body_html : String,
                   client_message_id : String, webhooks : Bool = true,
                   attachment : UploadedFile? = nil,
                   base_url : String = "") : Message
    now = Time.utc
    plain = plain_text(body_html)

    # One atomic transaction on the production DB: message + rich text + FTS5 + unread.
    # Atomicity is required for retry: a retry after "database is locked" must not leave
    # messages without body/index (the write_ack audit checks every record).
    #
    # The production transaction and job enqueueing go through Campfire::WriteQueue:
    # a single writer fiber per process (see write_queue.cr); broadcast and cache
    # invalidation happen after, outside the queue.
    message = Campfire::WriteQueue.perform do
      attachment_blob : ActiveStorage::Blob? = nil
      created = retry_on_lock do
        ActiveRecord::Base.transaction do
          # has_rich_text :body — the body= setter queues the rich_text row;
          # save! persists it through the after_save upsert (pinned conn).
          record = Message.new(
            room_id: room.id!,
            creator_id: creator.id!,
            client_message_id: client_message_id)
          record.body = body_html.empty? ? plain : body_html
          record.save! # belongs_to :room, touch: true touches rooms.updated_at
          message_id = record.id!

          conn = ActiveRecord::Base.__session # pinned transaction connection
          attachment_blob = Message::Attachment.store(conn, record, attachment, now) if attachment
          # indexMessage: a file without text is indexed by its filename.
          Message::Searchable.insert_in_index(conn, message_id,
            plain.presence || attachment.try(&.filename) || "")

          pending_jobs = notify(room, record, creator, body_html, webhooks)
          {record: record, jobs: pending_jobs}
        end
      end.not_nil!
      # Enqueue jobs (a separate queue DB) strictly AFTER the production transaction commits:
      # waiting for the queue's write lock inside another transaction held the production
      # write-lock and deadlocked both pools (full app deadlock observed at conc=16).
      Campfire::JobQueue.enqueue_batch(created[:jobs])
      {record: created[:record], jobs: created[:jobs], attachment_blob: attachment_blob}
    end
    # process_attachment (create_with_attachment!): eager :thumb/:poster before the
    # broadcast renders the presentation; failures are logged and posted without a preview.
    if (blob = message[:attachment_blob]?)
      Message::Attachment.process_attachment(blob)
    end
    # Broadcast with the attachment when a file was stored (attachMessage → publishMessage:
    # presentation instead of the rich-text body).
    record = message[:record]
    rendered = attachment ? ChatLayout.attachments_for([record.id!])[record.id!]? : nil
    Message::Broadcasts.broadcast_create(room, record, creator, rendered, base_url)
    record
  end

  # Room#receive: unread for members disconnected longer than 60 seconds, then collect
  # notification jobs; the caller enqueues them AFTER the production transaction commits.
  def self.notify(room : Room, message : Message, creator : User,
                  body_html : String, webhooks : Bool) : Array(Tuple(String, String))
    conn = ActiveRecord::Base.__session # pinned connection of the create! transaction
    room.unread_memberships(message)

    mentions = Message::Mentionee.mention_ids(body_html)
    direct = room.type == "Direct" # STI port stores short type names
    jobs = [] of Tuple(String, String)

    rows = conn.query_all(
      "SELECT m.user_id, u.role, u.status " \
      "FROM memberships m JOIN users u ON u.id = m.user_id " \
      "WHERE m.room_id = ? AND m.user_id <> ?",
      room.id!, creator.id!) do |rs|
      {user_id: rs.read(Int64), role: rs.read(Int32), status: rs.read(Int32)}
    end

    rows.each do |row|
      mentioned = mentions.includes?(row[:user_id])
      if webhooks && row[:status] == 0 && row[:role] == 2 && (direct || mentioned) &&
         (bot = User.find?(row[:user_id])) && (pair = bot.deliver_webhook_later(message))
        jobs << pair
      end
    end

    # Room::PushMessageJob: one push job per message; recipients (Room::MessagePusher) are filtered at delivery.
    jobs << room.push_later(message)
    # Message::BroadcastUnreadRoomJob: fan out the unread room to per-user sidebar streams.
    jobs << Message::Broadcasts.broadcast_unread_room_later(message)
    jobs
  end

  # Rough html→text for the FTS5 index: the contract only needs the body's words; tags are stripped.
  def self.plain_text(html : String) : String
    html.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
  end

  # Transactions start with BEGIN IMMEDIATE (like the Rails 8.1 sqlite3 adapter): the writer
  # takes the write lock up front and waits via the driver's busy_timeout. The retry guards
  # against busy_timeout expiry under heavy fork-worker contention — retrying the whole
  # transaction takes a fresh snapshot.
  private def self.retry_on_lock(attempts : Int32 = 5, &)
    tries = 0
    loop do
      tries += 1
      begin
        return yield
      rescue e : SQLite3::Exception
        if e.message.to_s.includes?("database is locked") && tries < attempts
          sleep Random.new.rand(0.005..0.05).seconds
          next
        end
        raise e
      end
    end
    raise Exception.new("unreachable") # excludes Nil from the return type
  end
end

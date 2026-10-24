require "uuid"

class MessagesController < ApplicationController
  include RawRequestBody
  include MessagesHelper

  # Upper bound on the request body: a message with its attachment goes as a single multipart POST.
  MAX_UPLOAD_BYTES = 100 * 1024 * 1024

  before_action :set_room, except: [:create]
  before_action :set_message, only: [:show, :edit, :update, :destroy]
  before_action :ensure_can_administer, only: [:edit, :update, :destroy]

  # Getters expose the ivars to the MessagesHelper ERB helpers.
  attr_reader room : Room?
  attr_reader message : Message?
  attr_reader mid : Int64?
  attr_reader messages : Array(Message) = [] of Message
  attr_reader message_html : String = ""
  attr_reader attachment : ChatLayout::Attachment?

  def index
    user = current_user.not_nil!

    # Whole-page cache (like rooms#show): the key includes the query (?before=...),
    # invalidated by the shared DB epoch.
    page = cache_page("messages#index", user.id) do
      messages = find_messages
      return head(:no_content) if messages.empty?
      @messages = messages
      Campfire::ResponseCache::Page.new(__render_view("index").to_s)
    end
    send_page(page)
  end

  def create
    return head(:payload_too_large) if upload_too_large?
    set_room
    return if @room.nil?
    room = @room.not_nil!
    user = current_user.not_nil!

    body_html = message_body_param
    client_message_id = message_client_id_param || UUID.random.to_s
    upload : MessageCreator::UploadedFile? = nil
    if form = parse_multipart_form
      if (item = form["message[attachment]"]?).is_a?(MessageCreator::UploadedFile)
        upload = item
      end
      if (cmid = form["message[client_message_id]"]?).is_a?(String) && !cmid.empty?
        client_message_id = cmid
      end
      if (text = form["message[body]"]?).is_a?(String) && !text.empty?
        body_html = text
      end
    end

    # Insert + rich text body + FTS5 index + broadcast + unread + queued notification
    # jobs, all persisted before the response; attachment → blob + attachment row.
    message = MessageCreator.create!(room, user, body_html, client_message_id,
      attachment: upload, base_url: origin)

    attachment = upload ? ChatLayout.attachments_for([message.id.not_nil!])[message.id.not_nil!]? : nil
    # Both deliveries contain the same token-free, viewer-independent markup.
    # Chomped: Rails' render_to_string of the partial swallows newlines after <% end %>.
    @message_html = ChatLayout.message_dom(message, room, user, attachment, base_url: origin).chomp
    render(html: __render_view("create", format: "turbo_stream").to_s,
      content_type: "text/vnd.turbo-stream.html")
  end

  def show
  end

  def edit
    message = @message.not_nil!
    @mid = message.id.not_nil!
    @attachment = ChatLayout.attachments_for([@mid.not_nil!])[@mid.not_nil!]?
  end

  def update
    message = @message.not_nil!
    room = @room.not_nil!

    Campfire::ResponseCache.invalidate!

    body_html = message_body_param
    plain = plain_text(body_html)
    now = Time.utc
    # Separate local so the queue closure does not capture message and lose nil-narrowing.
    target = message
    Campfire::WriteQueue.perform do
      conn = ActiveRecord::Base.connection
      conn.exec(
        "UPDATE action_text_rich_texts SET body = ?, updated_at = ? WHERE record_type = 'Message' AND record_id = ?",
        body_html.empty? ? plain : body_html, now, target.not_nil!.id.not_nil!)
      Message::Searchable.update_in_index(conn, target.not_nil!.id.not_nil!, plain)
      # Touch the message, like AR's update! bumping updated_at.
      target.not_nil!.touch
    end

    message = Message.find?(message.id.not_nil!).not_nil!
    mid = message.id.not_nil!
    broadcast_action_to([room, "messages"], :replace,
      target: "presentation_message_#{mid}",
      html: ChatLayout.presentation_dom(mid, ChatLayout.text_presentation(message.body.to_s)),
      attributes: {"maintain_scroll" => "true"})
    redirect_to room_message_url(room.id.not_nil!, mid)
  end

  def destroy
    message = @message.not_nil!
    room = @room.not_nil!

    Campfire::ResponseCache.invalidate!
    mid = message.id.not_nil!
    ActiveRecord::Base.connection.exec(
      "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", mid)
    Message::Searchable.remove_from_index(ActiveRecord::Base.connection, mid)
    message.destroy

    Campfire::ResponseCache.invalidate!

    broadcast_remove_to([room, "messages"], target: "message_#{mid}")
    render(html: __render_view("destroy", format: "turbo_stream").to_s,
      content_type: "text/vnd.turbo-stream.html")
  end

  # Bot-API (/rooms/:id/:bot_key/messages/**) lives in Messages::ByBotsController
  # and Messages::Boosts::ByBotsController (app/controllers/messages/).

  # RoomScoped#set_room: the room is looked up within the current user's memberships,
  # so a non-member gets 404 for reads and writes alike (create calls set_room by hand).
  private def set_room
    if room = current_user.not_nil!.rooms.find?(params["id"].to_s)
      @room = room
    else
      response.status = :not_found
      render(plain: "Room not found")
    end
  end

  private def set_message
    if (message = Message.find?(params["message_id"].to_s.to_i64)) &&
       message.room_id == @room.try(&.id)
      @message = message
    else
      response.status = :not_found
      render(plain: "Message not found")
    end
  end

  private def ensure_can_administer
    head :forbidden unless Current.user.not_nil!.can_administer?(@message)
  end

  private def find_messages : Array(Message)
    room = @room.not_nil!
    anchor = params["before"]?
    after_anchor = params["after"]?
    if anchor && (anchor_id = anchor.to_s.to_i64?)
      Message::Pagination.page_before(room, anchor_id)
    elsif after_anchor && (after_id = after_anchor.to_s.to_i64?)
      Message::Pagination.page_after(room, after_id)
    else
      Message::Pagination.last_page(room)
    end
  end

  private def message_params
    params.require(:message).permit(:body, :attachment, :client_message_id)
  end

  private def message_body_param : String
    value = message_params["body"]?
    value.to_s
  end

  private def message_client_id_param : String?
    v = message_params["client_message_id"]?
    v.nil? || v.to_s.empty? ? nil : v.to_s
  end

  # action_pack_cr parses only JSON and form-urlencoded, so multipart from file_uploader.js
  # (the file goes straight into the message POST) is parsed here: fields without a filename
  # are strings, with one — UploadedFile (bytes + content-type).
  private def upload_too_large? : Bool
    if (length = request.headers["Content-Length"]?.try(&.to_i64?)) &&
       length > MAX_UPLOAD_BYTES
      return true
    end
    false
  end

  private def parse_multipart_form : Hash(String, String | MessageCreator::UploadedFile)?
    content_type = request.headers["Content-Type"]?
    return nil unless content_type.try(&.includes?("multipart/form-data"))
    match = content_type.not_nil!.match(/boundary=([^";]+)/)
    return nil unless match
    boundary = match[1].strip('"')

    raw = raw_request_body
    return nil if raw.empty?
    delimiter = "--" + boundary
    start = raw.index(delimiter)
    return nil unless start
    rest = raw[(start + delimiter.size)..]

    form = {} of String => String | MessageCreator::UploadedFile
    rest.split("\r\n" + delimiter).each do |piece|
      next if piece.starts_with?("--") # closing --boundary--
      piece = piece[2..] if piece.starts_with?("\r\n")
      sep = piece.index("\r\n\r\n")
      next unless sep
      headers = piece[0...sep]
      content = piece[(sep + 4)..]
      name = headers[/name="([^"]*)"/, 1]?
      next unless name
      if (filename = headers[/filename="([^"]*)"/, 1]?) && !filename.empty?
        ctype = headers[/content-type:\s*([^\r\n]+)/i, 1]?.try(&.strip) ||
                "application/octet-stream"
        form[name] = MessageCreator::UploadedFile.new(filename, ctype, content.to_slice)
      else
        form[name] = content
      end
    end
    form
  end

  # Rough HTML → text for the FTS5 index: word presence is all the contract needs, so strip tags.
  private def plain_text(html : String) : String
    html.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
  end
end

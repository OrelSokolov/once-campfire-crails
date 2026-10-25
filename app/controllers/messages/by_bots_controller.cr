require "uuid"

class Messages::ByBotsController < ApplicationController
  include RawRequestBody
  helper :messages


  allow_bot_access
  skip_before_action :require_authentication

  before_action :require_bot, except: [:create]
  before_action :set_room, only: [:index, :show, :update, :destroy]
  before_action :set_message, only: [:update, :destroy]
  before_action :ensure_can_administer, only: [:update, :destroy]

  @messages : Array(Message) = [] of Message
  @message : Message?
  @room : Room?

  def index
    room = @room.not_nil!

    @messages = bot_messages_page(room)
    return if @performed
    if @messages.empty?
      return render(plain: "", status: :no_content)
    end

    conn = ActiveRecord::Base.connection
    total = conn.query_one(
      "SELECT count(*) FROM messages WHERE room_id = ?", room.id.not_nil!,
      as: Int64)
    response.headers["X-Total-Count"] = total.to_s
    direction = params["after"]? ? "after" : "before"
    anchor = direction == "after" ? @messages.last : @messages.first
    if (anchor_id = anchor.try(&.id))
      op = direction == "after" ? ">" : "<"
      has_next = conn.query_one?(
        "SELECT id FROM messages WHERE room_id = ? AND created_at #{op} " \
        "(SELECT created_at FROM messages WHERE id = ?) LIMIT 1",
        room.id.not_nil!, anchor_id, as: Int64)
      if has_next
        response.headers["Link"] =
          %(<#{origin}/rooms/#{room.id.not_nil!}/#{params["bot_key"]}/messages?#{direction}=#{anchor_id}>; rel="next")
      end
    end
    render(template: "messages/by_bots/index")
  end

  def show
    render(template: "messages/by_bots/show")
  end

  def create
    return head(:payload_too_large) if upload_too_large?
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!
    bot = bot_from_key
    return render(plain: "invalid bot key", status: 404) unless bot

    plain = raw_request_body
    body_html = HTML.escape(plain)
    client_message_id = UUID.random.to_s

    message = MessageCreator.create!(room, bot, body_html, client_message_id,
      base_url: origin)

    message_html = ChatLayout.message_dom(message, room, bot, base_url: origin).chomp
    # messages/create.turbo_stream.erb inline (the bot API answers with the
    # same append stream; the trailing \n is the erb template text).
    render(html: turbo_stream.append(dom_id(room, :messages), message_html).raw + "\n",
      content_type: "text/vnd.turbo-stream.html")
  end

  def update
    bot = bot_from_key.not_nil!
    room = @room.not_nil!
    message = @message.not_nil!


    plain = raw_request_body
    body_html = HTML.escape(plain)
    target = message
    Campfire::WriteQueue.perform do
      # update!(body:) — has_rich_text persists the row on save; save bumps
      # updated_at (the oracle's update!).
      target.not_nil!.body = body_html
      target.not_nil!.save
      Message::Searchable.update_in_index(ActiveRecord::Base.connection, target.not_nil!.id.not_nil!, plain)
    end

    mid = target.not_nil!.id.not_nil!
    message = Message.find?(mid).not_nil!
    broadcast_action_to([room, "messages"], :replace,
      target: "presentation_message_#{mid}",
      html: ChatLayout.presentation_dom(mid, ChatLayout.text_presentation(message.body.to_s)),
      attributes: {"maintain_scroll" => "true"})
    @message = message
    render(template: "messages/by_bots/show")
  end

  def destroy
    room = @room.not_nil!
    message = @message.not_nil!

    message.destroy


    broadcast_remove_to([room, "messages"], target: "message_#{message.id.not_nil!}")
    head(:no_content)
  end

  private def require_bot
    render(plain: "Unauthorized", status: :unauthorized) unless bot_from_key
  end

  MAX_UPLOAD_BYTES = MessagesController::MAX_UPLOAD_BYTES

  private def upload_too_large? : Bool
    if (length = request.headers["Content-Length"]?.try(&.to_i64?)) &&
       length > MAX_UPLOAD_BYTES
      return true
    end
    false
  end

  private def set_room
    if room = bot_room(bot_from_key.not_nil!)
      @room = room
    else
      render(plain: "Not Found", status: :not_found)
    end
  end

  private def set_message
    if (message = Message.find?(params["message_id"].to_s.to_i64)) &&
       message.room_id == @room.try(&.id)
      @message = message
    else
      render(plain: "Not Found", status: :not_found)
    end
  end

  private def ensure_can_administer
    head :forbidden unless bot_from_key.not_nil!.can_administer?(@message)
  end

  private def bot_from_key : User?
    User.authenticate_bot(params["bot_key"].to_s)
  end

  private def bot_room(bot : User) : Room?
    room = Room.find?(params["id"].to_s.to_i64)
    return nil unless room
    member = Membership.where(
      "room_id = ? AND user_id = ?", room.id.not_nil!, bot.id.not_nil!).take
    member ? room : nil
  end

  private def bot_messages_page(room : Room) : Array(Message)
    room_id = room.id.not_nil!
    anchor = params["before"]?
    after_anchor = params["after"]?
    if (anchor_id = anchor.try(&.to_s.to_i64?)) || (anchor_id = after_anchor.try(&.to_s.to_i64))
      pivot = ActiveRecord::Base.connection.query_one?(
        "SELECT created_at FROM messages WHERE id = ? AND room_id = ?",
        anchor_id.not_nil!, room_id, as: Time)
      unless pivot
        render(plain: "Not Found", status: :not_found)
        return [] of Message
      end
      op = after_anchor ? ">" : "<"
      ordering = after_anchor ? "ASC" : "DESC"
      # Time is bound through a subquery only: direct binding yields an
      # RFC3339 string while the column stores "YYYY-MM-DD HH:MM:SS(.mmm)",
      # so string comparison diverges (see messages#index).
      rows = Message.where(
        "room_id = ? AND created_at #{op} (SELECT created_at FROM messages WHERE id = ?)",
        room_id, anchor_id.not_nil!)
        .order("created_at #{ordering}").limit(40).to_a
      after_anchor ? rows : rows.reverse
    else
      Message.where("room_id = ?", room_id)
        .order("created_at DESC").limit(40).to_a.reverse
    end
  end
end

class Messages::Boosts::ByBotsController < ApplicationController
  include RawRequestBody

  allow_bot_access
  skip_before_action :require_authentication

  before_action :require_bot
  before_action :set_room_and_message
  before_action :set_boost, only: [:destroy]

  @boost : Boost?
  @room : Room?
  @message : Message?

  def create
    bot = bot_from_key.not_nil!
    message = @message.not_nil!
    room = @room.not_nil!
    mid = message.id!

    content = raw_request_body
    if content.strip.empty? || content.size > 16
      return head(:unprocessable_content)
    end

    now = Time.utc
    @boost = Campfire::WriteQueue.perform do
      record = Boost.new(message_id: mid, booster_id: bot.id!,
        content: content, created_at: now, updated_at: now)
      record.save!
      record
    end

    if (entry = ChatLayout.boosts_for([mid])[mid]?.try(&.last?))
      broadcast_action_to([room, "messages"], :append,
        target: "boosts_message_#{mid}",
        html: ChatLayout.boost_dom(mid, entry) + "\n",
        attributes: {"maintain_scroll" => "true"})
    end
    render(template: "messages/boosts/by_bots/show", status: :created)
  end

  def destroy
    message = @message.not_nil!
    boost = @boost.not_nil!

    Campfire::WriteQueue.perform do
      boost.destroy
    end

    if (room = Room.find?(message.room_id!))
      broadcast_remove_to([room, "messages"], target: "boost_#{params["boost_id"]}")
    end
    render(plain: "", status: :no_content)
  end

  private def require_bot
    render(plain: "Unauthorized", status: :unauthorized) unless bot_from_key
  end

  private def set_room_and_message
    message = Message.find?(params["message_id"].to_s.to_i64)
    room = message.try(&.room_id).try do |room_id|
      Room.find?(room_id).try do |r|
        Membership.where(
          "room_id = ? AND user_id = ?", r.id!,
          bot_from_key.not_nil!.id!).take ? r : nil
      end
    end
    if message && room && params["id"].to_s == room.id.to_s
      @message = message
      @room = room
    else
      render(plain: "Not Found", status: :not_found)
    end
  end

  private def set_boost
    @boost = Boost.where(
      "id = ? AND message_id = ? AND booster_id = ?",
      params["boost_id"].to_s.to_i64, @message.not_nil!.id!,
      bot_from_key.not_nil!.id!).take
    head(:not_found) unless @boost
  end

  private def bot_from_key : User?
    bot_key = params["bot_key"].to_s
    dash = bot_key.index('-')
    if dash && (bot_id = bot_key[0, dash].to_i64?)
      User.where(
        "id = ? AND bot_token = ? AND role = 2 AND status = 0",
        bot_id, bot_key[(dash + 1)..]).take
    end
  end
end

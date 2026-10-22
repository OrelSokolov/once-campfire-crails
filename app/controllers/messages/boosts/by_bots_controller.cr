# POST /rooms/:id/:bot_key/messages/:message_id/boosts — JSON-API бота
# (boosts by_bots create референса + routes.js): raw body как content
# (trim-непустой, ≤16 code points, иначе 422), broadcast append в комнату,
# 201 + messages/boosts/by_bots/bot_create.json.jbuilder (+ _boost/_user
# партиалы). Аутентификация по боту, не по сессии.
class Messages::Boosts::ByBotsController < ApplicationController
  skip_before_action :require_authentication

  before_action :require_bot
  before_action :set_room_and_message
  before_action :set_boost, only: [:bot_destroy]

  # jbuilder-вьюха bots-API (bot_create)
  @boost : Boost?
  @room : Room?
  @message : Message?

  def bot_create
    bot = bot_from_key.not_nil!
    message = @message.not_nil!
    room = @room.not_nil!
    mid = message.id.not_nil!

    content = request.body.try(&.gets_to_end).to_s
    if content.strip.empty? || content.size > 16
      # 422: :unprocessable_content — Rails 8+ имя (:unprocessable_entity
      # роняет status_code; заодно чиним тот же латентный баг в create)
      return head(:unprocessable_content)
    end

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    now = Time.utc
    @boost = Campfire::WriteQueue.perform do
      record = Boost.new(message_id: mid, booster_id: bot.id.not_nil!,
        content: content, created_at: now, updated_at: now)
      record.save! # belongs_to :message, touch: true трогает messages.updated_at
      record
    end

    if (entry = ChatLayout.boosts_for([mid])[mid]?.try(&.last?))
      # Как Messages::BoostsController#create (broadcast_create): \n
      # партиала _boost.html.erb — в template, maintain_scroll перед
      # action/target как в геме (attributes — через broadcast_action_to).
      broadcast_action_to([room, "messages"], :append,
        target: "boosts_message_#{mid}",
        html: ChatLayout.boost_dom(mid, entry) + "\n",
        attributes: {"maintain_scroll" => "true"})
    end
    render(template: "messages/boosts/by_bots/bot_create", status: :created)
  end

  # DELETE /rooms/:id/:bot_key/messages/:message_id/boosts/:boost_id —
  # снятие своего буста ботом (by_bots destroy: set_boost ищет по
  # booster == бот, broadcast_remove boost_<id>, 204).
  def bot_destroy
    message = @message.not_nil!
    boost = @boost.not_nil!

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    Campfire::WriteQueue.perform do
      # after_destroy коллбэк belongs_to :message, touch: true трогает
      # messages.updated_at
      boost.destroy
    end

    # by_bots destroy наследует broadcast_remove boosts_controller:
    # remove по dom_id буста в стриме комнаты.
    if (room = Room.find?(message.room_id.not_nil!))
      broadcast_remove_to([room, "messages"], target: "boost_#{params["boost_id"]}")
    end
    render(plain: "", status: :no_content)
  end

  private def require_bot
    render(plain: "Unauthorized", status: :unauthorized) unless bot_from_key
  end

  # Комната из пути (:id) + сообщение (:message_id) + membership бота —
  # как by_bots set_room/set_message референса.
  private def set_room_and_message
    message = Message.find?(params["message_id"].to_s.to_i64)
    room = message.try(&.room_id).try do |room_id|
      Room.find?(room_id).try do |r|
        Membership.where(
          "room_id = ? AND user_id = ?", r.id.not_nil!,
          bot_from_key.not_nil!.id.not_nil!).take ? r : nil
      end
    end
    if message && room && params["id"].to_s == room.id.to_s
      @message = message
      @room = room
    else
      render(plain: "Not Found", status: :not_found)
    end
  end

  # set_boost: буст этого сообщения, boostер — бот.
  private def set_boost
    @boost = Boost.where(
      "id = ? AND message_id = ? AND booster_id = ?",
      params["boost_id"].to_s.to_i64, @message.not_nil!.id.not_nil!,
      bot_from_key.not_nil!.id.not_nil!).take
    head(:not_found) unless @boost
  end

  # botUser(req) эталона: "<id>-<token>" → User (role=2, активный).
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

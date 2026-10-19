# POST /rooms/:id/:bot_key/messages/:message_id/boosts — JSON-API бота
# (boosts by_bots create референса + routes.js): raw body как content
# (trim-непустой, ≤16 code points, иначе 422), broadcast append в комнату,
# 201 + messages/boosts/by_bots/bot_create.json.jbuilder (+ _boost/_user
# партиалы). Аутентификация по боту, не по сессии.
class Messages::Boosts::ByBotsController < ApplicationController
  skip_before_action :require_authentication

  # jbuilder-вьюха bots-API (bot_create)
  @boost : Boost?

  def bot_create
    bot_key = params["bot_key"].to_s
    dash = bot_key.index('-')
    bot = if dash && (bot_id = bot_key[0, dash].to_i64?)
      User.where(
        "id = ? AND bot_token = ? AND role = 2 AND status = 0",
        bot_id, bot_key[(dash + 1)..]).take
    end
    unless bot
      return render(plain: "Unauthorized", status: :unauthorized)
    end
    bot = bot.not_nil!
    message = Message.find?(params["message_id"].to_s.to_i64)
    room = message.try(&.room_id).try do |room_id|
      Room.find?(room_id).try do |r|
        Membership.where(
          "room_id = ? AND user_id = ?", r.id.not_nil!, bot.id.not_nil!).take ? r : nil
      end
    end
    unless message && room && params["id"].to_s == room.id.to_s
      return render(plain: "Not Found", status: :not_found)
    end
    message = message.not_nil!
    room = room.not_nil!
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
      record.save!
      # belongs_to :message, touch: true
      ActiveRecord::Base.connection.exec(
        "UPDATE messages SET updated_at = ? WHERE id = ?", now, mid)
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
end

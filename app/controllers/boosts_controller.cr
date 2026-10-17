# Boosts — бусты сообщения (messages/boosts_controller.rb референса).
# Роуты вложены в сообщение (/messages/:message_id/boosts), стрим —
# комната сообщения ([room, :messages]).
#
#   GET    /messages/:message_id/boosts        — index (boosts-partial в
#            turbo-frame message_<id>_boosting; redirect-цель формы буста)
#   GET    /messages/:message_id/boosts/new    — new (форма в лениво
#            загружаемый фрейм message_<id>_new_boost)
#   POST   /messages/:message_id/boosts        — create: broadcast append
#            boost в контейнер message_<id>_boosts (maintain_scroll) +
#            redirect на index (фрейм message_<id>_boosting)
#   DELETE /messages/:message_id/boosts/:id    — destroy своего буста:
#            broadcast remove boost_<id>
class BoostsController < ApplicationController
  include BoostsHelpers

  skip_before_action :require_authentication, only: :bot_create

  # jbuilder-вьюха bots-API (bot_create)
  @boost : Boost?

  # ERB-вьюхи index/new (implicit render: app/views/boosts/*.html.erb —
  # контроллер готовит данные, разметка в шаблонах, как в референсе);
  # boosts_dom (BoostsHelpers) читает mid/boosts — геттеры.
  @message : Message?
  @user : User?
  getter mid : Int64?
  getter boosts : Array(ChatLayout::BoostEntry) = [] of ChatLayout::BoostEntry
  # set_message: Current.user.reachable_messages.find(params[:message_id])
  # — сообщение из комнаты, доступной текущему юзеру (membership).
  private def find_reachable_message : Message?
    message = Message.find?(params["message_id"].to_s.to_i64)
    return nil unless message
    user = current_user.not_nil!
    member = Membership.where(
      "room_id = ? AND user_id = ?", message.room_id.not_nil!, user.id.not_nil!).take
    member ? message : nil
  end

  # GET /messages/:message_id/boosts — index.html.erb (boosts partial).
  def index
    message = find_reachable_message
    return head(:not_found) unless message
    @message = message
    mid = message.id.not_nil!
    @mid = mid
    @boosts = ChatLayout.boosts_for([mid])[mid]? || [] of ChatLayout::BoostEntry
  end

  # GET /messages/:message_id/boosts/new — new.html.erb: форма кастомного
  # буста в turbo-frame message_<id>_new_boost (submit в фрейм boosting).
  def new
    message = find_reachable_message
    return head(:not_found) unless message
    @message = message
    @mid = message.id.not_nil!
    @user = current_user.not_nil!
  end

  # POST /messages/:message_id/boosts — boost_params (boost[content]),
  # создание + touch сообщения (инвалидация fragment-кэша), broadcast
  # append в контейнер message_<id>_boosts (maintain_scroll), redirect
  # на index (Turbo подставляет ответ в фрейм message_<id>_boosting).
  def create
    message = find_reachable_message
    return head(:not_found) unless message
    user = current_user.not_nil!
    content = boost_content_param
    return head(:unprocessable_content) if content.empty?

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    message = message.not_nil!
    mid = message.id.not_nil!
    now = Time.utc
    boost = Campfire::WriteQueue.perform do
      record = Boost.new(message_id: mid, booster_id: user.id.not_nil!,
        content: content, created_at: now, updated_at: now)
      record.save!
      # belongs_to :message, touch: true —Rails трогает messages.updated_at
      ActiveRecord::Base.connection.exec(
        "UPDATE messages SET updated_at = ? WHERE id = ?", now, mid)
      record
    end

    room = Room.find?(message.room_id.not_nil!)
    if room
      entry = ChatLayout.boosts_for([mid])[mid]?.try(&.last?)
      if entry
        stream = %(<turbo-stream action="append" target="boosts_message_#{mid}" maintain_scroll="true"><template>) +
          ChatLayout.boost_dom(mid, entry) + %(</template></turbo-stream>\n)
        Campfire.broadcast(
          Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
          stream)
      end
    end
    redirect_to "/messages/#{mid}/boosts"
  end

  # POST /rooms/:id/:bot_key/messages/:message_id/boosts — JSON-API
  # бота (boosts by_bots create референса + routes.js): raw body как
  # content (trim-непустой, ≤16 code points, иначе 422), broadcast
  # append в комнату, 201 + boosts/bot_create.json.jbuilder (+
  # _boost/_user партиалы).
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
      stream = %(<turbo-stream action="append" target="boosts_message_#{mid}" maintain_scroll="true"><template>) +
        ChatLayout.boost_dom(mid, entry) + %(</template></turbo-stream>\n)
      Campfire.broadcast(
        Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
        stream)
    end
    render(template: "boosts/bot_create", status: :created)
  end

  # DELETE /messages/:message_id/boosts/:id — удаление своего буста,
  # broadcast remove boost_<id>.
  def destroy
    message = find_reachable_message
    return head(:not_found) unless message
    message = message.not_nil!
    user = current_user.not_nil!
    boost_id = params["id"].to_s.to_i64
    boost = Boost.where(
      "id = ? AND message_id = ? AND booster_id = ?",
      boost_id, message.id.not_nil!, user.id.not_nil!).take
    return head(:not_found) unless boost

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    now = Time.utc
    mid = message.id.not_nil!
    Campfire::WriteQueue.perform do
      boost.not_nil!.destroy
      ActiveRecord::Base.connection.exec(
        "UPDATE messages SET updated_at = ? WHERE id = ?", now, mid)
    end

    if (room = Room.find?(message.room_id.not_nil!))
      stream = %(<turbo-stream action="remove" target="boost_#{boost_id}"></turbo-stream>\n)
      Campfire.broadcast(
        Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
        stream)
    end
    render(plain: "", status: :no_content)
  end

  private def boost_content_param : String
    nested = params["boost"]?
    value = case nested
            when ActionController::Parameters then nested["content"]?
            else nested ? nested : nil
            end
    value.to_s
  end
end

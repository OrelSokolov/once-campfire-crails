# Boosts — бусты сообщения (messages/boosts_controller.rb референса).
# Роуты вложены в сообщение (/messages/:message_id/boosts), стрим —
# комната сообщения ([room, :messages]). Bot-API создания буста — в
# Messages::Boosts::ByBotsController.
class Messages::BoostsController < ApplicationController
  include BoostsHelpers

  before_action :set_message
  before_action :set_boost, only: [:destroy]

  # ERB-вьюхи index/new (implicit render: app/views/messages/boosts/*.html.erb —
  # контроллер готовит данные, разметка в шаблонах, как в референсе);
  # boosts_dom (BoostsHelpers) читает mid/boosts — геттеры.
  @message : Message?
  @user : User?
  @boost : Boost?
  attr_reader mid : Int64?
  attr_reader boosts : Array(ChatLayout::BoostEntry) = [] of ChatLayout::BoostEntry

  # GET /messages/:message_id/boosts — index.html.erb (boosts partial).
  def index
    message = @message.not_nil!
    mid = message.id.not_nil!
    @mid = mid
    @boosts = ChatLayout.boosts_for([mid])[mid]? || [] of ChatLayout::BoostEntry
  end

  # GET /messages/:message_id/boosts/new — new.html.erb: форма кастомного
  # буста в turbo-frame message_<id>_new_boost (submit в фрейм boosting).
  def new
    @mid = @message.not_nil!.id.not_nil!
    @user = current_user.not_nil!
  end

  # POST /messages/:message_id/boosts — boost_params (boost[content]),
  # создание + touch сообщения (инвалидация fragment-кэша), broadcast
  # append в контейнер message_<id>_boosts (maintain_scroll), redirect
  # на index (Turbo подставляет ответ в фрейм message_<id>_boosting).
  def create
    message = @message.not_nil!
    user = current_user.not_nil!
    content = boost_params["content"]?.to_s
    return head(:unprocessable_content) if content.empty?

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    mid = message.id.not_nil!
    now = Time.utc
    boost = Campfire::WriteQueue.perform do
      record = Boost.new(message_id: mid, booster_id: user.id.not_nil!,
        content: content, created_at: now, updated_at: now)
      record.save! # belongs_to :message, touch: true трогает messages.updated_at
      record
    end

    room = Room.find?(message.room_id.not_nil!)
    if room
      entry = ChatLayout.boosts_for([mid])[mid]?.try(&.last?)
      if entry
        # boosts_controller.rb#broadcast_create: broadcast_append_to room,
        # :messages, target: dom_id(message, :boosts), partial: boost
        # (_boost.html.erb заканчивается \n — идёт вместе с партиалом),
        # attributes: { maintain_scroll: true }. ActionHelper ставит
        # maintain_scroll ПЕРЕД action/target — как **attributes гема;
        # в turbo_cr attributes пробрасывает broadcast_action_to.
        broadcast_action_to([room, "messages"], :append,
          target: "boosts_message_#{mid}",
          html: ChatLayout.boost_dom(mid, entry) + "\n",
          attributes: {"maintain_scroll" => "true"})
      end
    end
    redirect_to message_boosts_path(mid)
  end

  # DELETE /messages/:message_id/boosts/:id — удаление своего буста,
  # broadcast remove boost_<id>.
  def destroy
    message = @message.not_nil!
    boost = @boost.not_nil!

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    mid = message.id.not_nil!
    Campfire::WriteQueue.perform do
      # after_destroy коллбэк belongs_to :message, touch: true трогает
      # messages.updated_at
      boost.destroy
    end

    # boosts_controller.rb#broadcast_remove: broadcast_remove_to room,
    # :messages (target — dom_id буста).
    if (room = Room.find?(message.room_id.not_nil!))
      broadcast_remove_to([room, "messages"], target: "boost_#{params["id"]}")
    end
    render(plain: "", status: :no_content)
  end

  # set_message референса: Current.user.reachable_messages.find — сообщение
  # из комнаты, доступной текущему юзеру (membership).
  private def set_message
    message = Message.find?(params["message_id"].to_s.to_i64)
    if message && Membership.where(
        "room_id = ? AND user_id = ?", message.room_id.not_nil!,
        Current.user.not_nil!.id.not_nil!).take
      @message = message
    else
      head(:not_found)
    end
  end

  # set_boost референса: @message.boosts.find_by!(id:, booster: Current.user).
  private def set_boost
    @boost = Boost.where(
      "id = ? AND message_id = ? AND booster_id = ?",
      params["id"].to_s.to_i64, @message.not_nil!.id.not_nil!,
      Current.user.not_nil!.id.not_nil!).take
    head(:not_found) unless @boost
  end

  private def boost_params
    params.require("boost").permit("content")
  end
end

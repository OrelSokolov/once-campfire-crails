class Messages::BoostsController < ApplicationController
  include BoostsHelpers

  before_action :set_message
  before_action :set_boost, only: [:destroy]

  @message : Message?
  @user : User?
  @boost : Boost?
  attr_reader mid : Int64?
  attr_reader boosts : Array(ChatLayout::BoostEntry) = [] of ChatLayout::BoostEntry

  def index
    message = @message.not_nil!
    mid = message.id.not_nil!
    @mid = mid
    @boosts = ChatLayout.boosts_for([mid])[mid]? || [] of ChatLayout::BoostEntry
  end

  def new
    @mid = @message.not_nil!.id.not_nil!
    @user = current_user.not_nil!
  end

  def create
    message = @message.not_nil!
    user = current_user.not_nil!
    content = boost_params["content"]?.to_s
    return head(:unprocessable_content) if content.empty?

    Campfire::ResponseCache.invalidate!
    mid = message.id.not_nil!
    now = Time.utc
    boost = Campfire::WriteQueue.perform do
      record = Boost.new(message_id: mid, booster_id: user.id.not_nil!,
        content: content, created_at: now, updated_at: now)
      record.save!
      record
    end

    room = Room.find?(message.room_id.not_nil!)
    if room
      entry = ChatLayout.boosts_for([mid])[mid]?.try(&.last?)
      if entry
        broadcast_action_to([room, "messages"], :append,
          target: "boosts_message_#{mid}",
          html: ChatLayout.boost_dom(mid, entry) + "\n",
          attributes: {"maintain_scroll" => "true"})
      end
    end
    redirect_to message_boosts_url(mid)
  end

  def destroy
    message = @message.not_nil!
    boost = @boost.not_nil!

    Campfire::ResponseCache.invalidate!
    mid = message.id.not_nil!
    Campfire::WriteQueue.perform do
      boost.destroy
    end

    if (room = Room.find?(message.room_id.not_nil!))
      broadcast_remove_to([room, "messages"], target: "boost_#{params["id"]}")
    end
    render(plain: "", status: :no_content)
  end

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

  private def set_boost
    @boost = Boost.where(
      "id = ? AND message_id = ? AND booster_id = ?",
      params["id"].to_s.to_i64, @message.not_nil!.id.not_nil!,
      Current.user.not_nil!.id.not_nil!).take
    head(:not_found) unless @boost
  end

  private def boost_params
    params.require(:boost).permit(:content)
  end
end

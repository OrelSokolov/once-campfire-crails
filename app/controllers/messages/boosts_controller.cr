class Messages::BoostsController < ApplicationController
  helper :boosts

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

  # Current.user.reachable_messages.find — the oracle's boost authorization
  # scope (rooms reached through memberships); RecordNotFound → 404 middleware.
  private def set_message
    @message = Current.user.not_nil!.reachable_messages
      .find(params["message_id"].to_s)
  end

  private def set_boost
    # @message.boosts.find_by!(id: ..., booster: Current.user) — the message
    # association scope plus the booster filter; miss → 404 middleware.
    @boost = @message.not_nil!.boosts
      .where("booster_id = ?", Current.user.not_nil!.id.not_nil!)
      .find(params["id"].to_s)
  end

  private def boost_params
    params.require(:boost).permit(:content)
  end
end

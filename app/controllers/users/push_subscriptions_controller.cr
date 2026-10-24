class Users::PushSubscriptionsController < ApplicationController
  include PushSubscriptionsHelpers

  @push_subscriptions : Array(Push::Subscription) = [] of Push::Subscription

  compile_partials({
    "users/push_subscriptions/push_subscription" => {
      path: "app/views/users/push_subscriptions/_push_subscription.html.erb",
      locals: {"push_subscription" => Push::Subscription},
    },
  }, dedent: true)

  def index
    @push_subscriptions = Push::Subscription
      .where("user_id = ?", current_user.not_nil!.id.not_nil!)
      .order("id").to_a
  end

  def create
    user = current_user.not_nil!
    endpoint = nested("endpoint")
    p256dh = nested("p256dh_key")
    auth = nested("auth_key")

    existing = Push::Subscription.where(
      "user_id = ? AND endpoint = ? AND p256dh_key = ? AND auth_key = ?",
      user.id.not_nil!, endpoint, p256dh, auth).take
    if existing
      # Existing endpoints must pass current validations
      if existing.valid_subscription?
        existing.touch
        head :ok
      else
        head :unprocessable_entity
      end
    else
      subscription = Push::Subscription.new(
        user_id: user.id.not_nil!,
        endpoint: endpoint,
        p256dh_key: p256dh,
        auth_key: auth,
        user_agent: request.headers["User-Agent"]?)
      if subscription.valid_subscription?
        subscription.save!
        head :ok
      else
        head :unprocessable_entity
      end
    end
  end

  def destroy
    Campfire::ResponseCache.invalidate!
    Push::Subscription.where("user_id = ? AND id = ?",
      current_user.not_nil!.id.not_nil!, params["id"].to_s).delete_all
    redirect_to user_push_subscriptions_url
  end

  private def nested(key : String) : String
    nested = params["push_subscription"]?
    return "" unless nested.is_a?(ActionController::Parameters)
    value = nested[key]?
    value.nil? ? "" : value.to_s
  end
end

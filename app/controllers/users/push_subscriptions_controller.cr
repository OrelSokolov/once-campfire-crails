# /users/me/push_subscriptions — подписки текущего пользователя на Web
# Push (users/push_subscriptions_controller.rb референса): список,
# регистрация новой (JS-колокол _bell.html.erb POST-ит
# {push_subscription:{endpoint,p256dh_key,auth_key}}), удаление.
# Совпавшая endpoint-тройка — touch существующей подписки (и повторная
# валидация), иначе create с user_agent; невалидный endpoint — 422.
class Users::PushSubscriptionsController < ApplicationController
  include PushSubscriptionsHelpers

  @push_subscriptions : Array(PushSubscription) = [] of PushSubscription

  # Строка списка (users/push_subscriptions/_push_subscription.html.erb).
  compile_partials({
    "users/push_subscriptions/push_subscription" => {
      path: "app/views/users/push_subscriptions/_push_subscription.html.erb",
      locals: {"push_subscription" => PushSubscription},
    },
  }, dedent: true)

  def index
    @push_subscriptions = PushSubscription
      .where("user_id = ?", current_user.not_nil!.id.not_nil!)
      .order("id").to_a
  end

  def create
    user = current_user.not_nil!
    endpoint = nested("endpoint")
    p256dh = nested("p256dh_key")
    auth = nested("auth_key")

    existing = PushSubscription.where(
      "user_id = ? AND endpoint = ? AND p256dh_key = ? AND auth_key = ?",
      user.id.not_nil!, endpoint, p256dh, auth).take
    if existing
      if existing.valid_subscription?
        existing.touch
        head :ok
      else
        head :unprocessable_entity
      end
    else
      subscription = PushSubscription.new(
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
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    PushSubscription.where("user_id = ? AND id = ?",
      current_user.not_nil!.id.not_nil!, params["id"].to_s).delete_all
    redirect_to "/users/me/push_subscriptions"
  end

  private def nested(key : String) : String
    nested = params["push_subscription"]?
    return "" unless nested.is_a?(ActionController::Parameters)
    value = nested[key]?
    value.nil? ? "" : value.to_s
  end
end

class Users::PushSubscriptions::TestNotificationsController < ApplicationController
  def create
    user = current_user.not_nil!
    subscription = Push::Subscription.where("user_id = ? AND id = ?",
      user.id.not_nil!, params["push_subscription_id"].to_s).take

    if subscription && (vapid_private = ENV["VAPID_PRIVATE_KEY"]?) &&
       (vapid_public = ENV["VAPID_PUBLIC_KEY"]?)
      deliver(user, subscription, vapid_public, vapid_private)
    end
    redirect_to user_push_subscriptions_url
  end

  # 404/410 (ExpiredSubscription) deletes the subscription; other errors are logged.
  private def deliver(user : User, subscription : Push::Subscription,
                      vapid_public : String, vapid_private : String) : Nil
    badge = ActiveRecord::Base.connection.query_one(
      "SELECT count(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL",
      user.id.not_nil!, as: Int64)
    payload = JSON.build do |j|
      j.object do
        j.field "title", "Campfire Test"
        j.field "options" do
          j.object do
            j.field "body", UUID.random.to_s
            j.field "icon", "/account/logo"
            j.field "data" do
              j.object do
                j.field "path", "#{origin}/users/me/push_subscriptions"
                j.field "badge", badge
              end
            end
          end
        end
      end
    end
    status = Campfire::WebPush.deliver(subscription.endpoint.to_s,
      subscription.p256dh_key.to_s, subscription.auth_key.to_s, payload,
      vapid_public, vapid_private,
      ENV["VAPID_SUBJECT"]? || "mailto:campfire@example.com")
    return if status.nil?
    subscription.delete if {404, 410}.includes?(status)
  rescue e
    STDERR.puts "Campfire test push failed: #{e.message}"
  end
end

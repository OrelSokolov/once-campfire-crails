require "../application_job"

class Bot::WebhookJob < ApplicationJob
  serialized bot: User, message: Message

  def self.queue_kind : String
    "webhook"
  end

  def perform(bot : User, message : Message) : Nil
    bot.deliver_webhook(message)
  end
end

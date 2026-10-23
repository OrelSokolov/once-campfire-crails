require "../application_record"

# User::Bot (user/bot.rb): токен бота, аутентификация по bot_key,
# webhook-URL (deliver_webhook — Bot::WebhookJob в app/jobs).
class User
  module Bot
    include ActiveSupport::Concern

    class_methods do
      # SecureRandom.alphanumeric(12) Rails (generate_bot_token):
      # [A-Za-z0-9]{12} ≈ 71 бит энтропии (hex(6) давал 48).
      BOT_TOKEN_CHARSET = ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a

      def generate_bot_token : String
        String.build(12) do |io|
          12.times { io << BOT_TOKEN_CHARSET[Random::Secure.rand(BOT_TOKEN_CHARSET.size)] }
        end
      end

      # User.authenticate_bot оракула: "<id>-<token>" → активный бот.
      # Токен сравнивается constant-time (Crypto::Subtle), не SQL-строкой.
      def authenticate_bot(bot_key : String) : User?
        dash = bot_key.index('-')
        return nil unless dash && (bot_id = bot_key[0, dash].to_i64?)
        bot = where("id = ? AND role = 2 AND status = 0", bot_id).take
        return nil unless bot
        token = bot.bot_token.to_s
        return nil if token.empty?
        Crypto::Subtle.constant_time_compare(token, bot_key[(dash + 1)..]) ? bot : nil
      end
    end

    macro included
      extend_class_methods!
    end

    # Единственный webhook бота (таблица webhooks; user_id, url).
    def webhook_url : String?
      ActiveRecord::Base.connection.query_one?(
        "SELECT url FROM webhooks WHERE user_id = ?", id.not_nil!) { |rs| rs.read(String?) }
    end
  end
  include Bot
end

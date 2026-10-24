require "../application_record"

class User
  module Bot
    include ActiveSupport::Concern

    class_methods do
      BOT_TOKEN_CHARSET = ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a

      def generate_bot_token : String
        String.build(12) do |io|
          12.times { io << BOT_TOKEN_CHARSET[Random::Secure.rand(BOT_TOKEN_CHARSET.size)] }
        end
      end

      # Oracle's User.authenticate_bot: "<id>-<token>" → active bot.
      # The token is compared constant-time (Crypto::Subtle), not in SQL.
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

    def webhook_url : String?
      ActiveRecord::Base.connection.query_one?(
        "SELECT url FROM webhooks WHERE user_id = ?", id.not_nil!) { |rs| rs.read(String?) }
    end
  end
  include Bot
end

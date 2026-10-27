require "../application_record"
require "json"
require "uuid"

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

    def bot_key : String
      "#{id}-#{bot_token}"
    end

    def webhook_url : String?
      ActiveRecord::Base.connection.query_one?(
        "SELECT url FROM webhooks WHERE user_id = ?", id.not_nil!) { |rs| rs.read(String?) }
    end

    # Bot::WebhookJob enqueue tuple — the JobQueue DB write must stay outside
    # the production transaction (see MessageCreator#create!).
    def deliver_webhook_later(message : Message) : Tuple(String, String)?
      ::Bot::WebhookJob.__queue_pair(self, message) if webhook_url
    end

    # Oracle's Webhook#deliver (no Webhook model in the port — the row is
    # resolved by the bot's id, see notes/known-gaps.md).
    def deliver_webhook(message : Message) : Nil
      return unless (url = webhook_url) && active?
      msg = nil

      conn = ActiveRecord::Base.connection
      msg = conn.query_one?(
        "SELECT m.id, m.room_id, m.creator_id, r.name AS room_name, u.name AS creator_name " \
        "FROM messages m " \
        "JOIN rooms r ON r.id = m.room_id JOIN users u ON u.id = m.creator_id WHERE m.id = ?",
        message.id!) do |rs|
        {id: rs.read(Int64), room_id: rs.read(Int64), creator_id: rs.read(Int64),
         room_name: rs.read(String?), creator_name: rs.read(String?)}
      end
      return unless msg
      return unless conn.query_one?(
        "SELECT 1 FROM memberships WHERE user_id = ? AND room_id = ?",
        id.not_nil!, msg[:room_id]) { |rs| rs.read(Int32) }

      body = conn.query_one?(
        "SELECT body FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?",
        msg[:id]) { |rs| rs.read(String) }.to_s

      payload = JSON.build do |j|
        j.object do
          j.field "user" do
            j.object do
              j.field "id", msg[:creator_id]
              j.field "name", msg[:creator_name]
            end
          end
          j.field "room" do
            j.object do
              j.field "id", msg[:room_id]
              j.field "name", msg[:room_name]
              j.field "path", "/rooms/#{msg[:room_id]}/#{bot_key}/messages"
            end
          end
          j.field "message" do
            j.object do
              j.field "id", msg[:id]
              j.field "body" do
                j.object do
                  j.field "html", body
                  j.field "plain", MessageCreator.plain_text(body)
                end
              end
              j.field "path", "/rooms/#{msg[:room_id]}/@#{msg[:id]}"
            end
          end
        end
      end

      uri = URI.parse(url)
      if !{"http", "https"}.includes?(uri.scheme) || uri.user || uri.password
        raise "invalid webhook URL"
      end

      if (reply_text = post_webhook(uri, payload))
        webhook_reply(msg[:room_id], reply_text)
      end
    rescue IO::TimeoutError
      if msg
        webhook_reply(msg[:room_id], "Failed to respond within 7 seconds")
      end
    end

    private def post_webhook(uri : URI, payload : String) : String?
      # POST JSON; a 200 text/* response body becomes the bot's reply, else nil.
      client = HTTP::Client.new(uri)
      client.connect_timeout = 7.seconds
      client.read_timeout = 7.seconds
      response = client.post(uri.request_target.not_nil!,
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: payload)
      content_type = response.headers["Content-Type"]?.to_s.split(";").first?
      if response.status_code == 200 &&
         {"text/plain", "text/html"}.includes?(content_type) &&
         !response.body.empty?
        response.body
      end
    end

    # The bot's reply is a message created on its behalf (webhooks: false,
    # as notifyMessage(result, { webhooks: false }) in the express reference).
    private def webhook_reply(room_id : Int64, text : String) : Nil
      return unless (room = Room.find?(room_id))
      body_html = "<p>#{HTML.escape(text)}</p>"
      MessageCreator.create!(room, self, body_html, UUID.random.to_s,
        webhooks: false)
    end
  end
  include Bot
end

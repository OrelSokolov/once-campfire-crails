require "../application_job"
require "uuid"

class Bot::WebhookJob < ApplicationJob
  # Oracle: perform(bot, message); the port resolves the webhook row by id
  # (no Webhook model — see notes/known-gaps.md).
  serialized webhook_id: Int64, message: Message

  def self.queue_kind : String
    "webhook"
  end

  def perform(webhook_id : Int64, message : Message) : Nil
    hook = nil
    msg = nil

    conn = ActiveRecord::Base.connection
    hook = conn.query_one?(
      "SELECT w.id, w.url, w.user_id, u.name, u.bot_token, u.status " \
      "FROM webhooks w JOIN users u ON u.id = w.user_id WHERE w.id = ?",
      webhook_id) do |rs|
      {id: rs.read(Int64), url: rs.read(String?), user_id: rs.read(Int64),
       name: rs.read(String?), bot_token: rs.read(String?), status: rs.read(Int32)}
    end
    return unless hook && hook[:status] == 0

    message_id = message.id!
    msg = conn.query_one?(
      "SELECT m.id, m.room_id, m.creator_id, r.name AS room_name, r.type AS room_type, " \
      "u.name AS creator_name FROM messages m " \
      "JOIN rooms r ON r.id = m.room_id JOIN users u ON u.id = m.creator_id WHERE m.id = ?",
      message_id) do |rs|
      {id: rs.read(Int64), room_id: rs.read(Int64), creator_id: rs.read(Int64),
       room_name: rs.read(String?), room_type: rs.read(String?),
       creator_name: rs.read(String?)}
    end
    return unless msg
    return unless conn.query_one?(
      "SELECT 1 FROM memberships WHERE user_id = ? AND room_id = ?",
      hook[:user_id], msg[:room_id]) { |rs| rs.read(Int32) }

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
            j.field "path", "/rooms/#{msg[:room_id]}/#{hook[:user_id]}-#{hook[:bot_token]}/messages"
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

    url = URI.parse(hook[:url].to_s)
    if !{"http", "https"}.includes?(url.scheme) || url.user || url.password
      raise "invalid webhook URL"
    end

    reply_text = self.class.deliver_webhook(url, payload)
    if reply_text
      self.class.webhook_reply(hook[:user_id], msg[:room_id], reply_text)
    end
  rescue IO::TimeoutError
    if hook && msg
      self.class.webhook_reply(hook[:user_id], msg[:room_id],
        "Failed to respond within 7 seconds")
    end
  end

  # POST JSON; a 200 text/* response body becomes the bot's reply, else nil.
  def self.deliver_webhook(url : URI, payload : String) : String?
    client = HTTP::Client.new(url)
    client.connect_timeout = 7.seconds
    client.read_timeout = 7.seconds
    response = client.post(url.request_target.not_nil!,
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
  def self.webhook_reply(bot_id : Int64, room_id : Int64, text : String) : Nil
    room = Room.find?(room_id)
    bot = User.find?(bot_id)
    return unless room && bot
    body_html = "<p>#{HTML.escape(text)}</p>"
    MessageCreator.create!(room, bot, body_html, UUID.random.to_s,
      webhooks: false)
  end
end

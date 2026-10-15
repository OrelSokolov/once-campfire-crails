# Smoke: создаёт сессию для David в dev-БД и печатает подписанную
# cookie session_token (тем же секретом, что и приложение).
require "../src/app_boot_models"
require "http"

ActiveRecord::Base.establish_connection_from_yaml(
  "config/database.yml", CRails.env.to_s.downcase)
CRails.application.initialize!

token = "smoketoken#{Time.utc.to_unix_ms}"
now = Time.utc
ActiveRecord::Base.connection.exec(
  "INSERT INTO sessions (user_id, token, user_agent, ip_address, last_active_at, created_at, updated_at) VALUES (?, ?, 'curl', '127.0.0.1', ?, ?, ?)",
  127326141_i64, token, now, now, now)

headers = HTTP::Headers.new
request = HTTP::Request.new("GET", "/", headers)
io = IO::Memory.new
response = HTTP::Server::Response.new(io)
ctx = HTTP::Server::Context.new(request, response)
jar = ActionController::Cookies.new(ctx)
jar.signed.set("session_token", token,
  expires: Time.utc + 20.years, httponly: true, same_site: :lax)
line = ctx.response.headers.get("Set-Cookie").first
puts line.split(';').first

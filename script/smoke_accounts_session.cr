# Разовый smoke рефакторинга accounts (не компилируется в bin/app):
# сессии для админа (user 2, role=1) и не-админа (user 999, role=0)
# в tmp-копии dev-БД; печатает две подписанные cookie session_token.
#   DATABASE_URL=sqlite3://tmp/smoke_refactor.sqlite3 SECRET_KEY_BASE=... \
#     crystal run tmp/smoke_accounts_session.cr
require "../src/app_boot_models"
require "http"

CRails.application.initialize!

def mint_session(user_id : Int64, role : Int32) : String
  token = "smoke#{user_id}#{Time.utc.to_unix_ms}"
  now = Time.utc
  ActiveRecord::Base.connection.exec(
    "INSERT OR REPLACE INTO users (id, email_address, name, role, status, created_at, updated_at) VALUES (?, ?, 'Smoke Member', ?, 0, ?, ?)",
    user_id, "smoke#{user_id}@example.com", role, now, now)
  ActiveRecord::Base.connection.exec(
    "INSERT INTO sessions (user_id, token, user_agent, ip_address, last_active_at, created_at, updated_at) VALUES (?, ?, 'curl', '127.0.0.1', ?, ?, ?)",
    user_id, token, now, now, now)
  token
end

def signed_cookie(token : String) : String
  headers = HTTP::Headers.new
  request = HTTP::Request.new("GET", "/", headers)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  ctx = HTTP::Server::Context.new(request, response)
  jar = ActionController::Cookies.new(ctx)
  jar.signed.set("session_token", token,
    expires: Time.utc + 20.years, httponly: true, same_site: :lax)
  ctx.response.headers.get("Set-Cookie").first.split(';').first
end

puts signed_cookie(mint_session(2_i64, 1))     # админ
puts signed_cookie(mint_session(998_i64, 0))   # обычный юзер

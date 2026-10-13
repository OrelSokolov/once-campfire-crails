require "http"
require "../lib/action_pack_cr/src/action_pack_cr"

SECRET = "b3c641c1e9d1e0e4a1e1c6e8e5b7d2f4a9c0d3e6f1a2b4c5d6e7f8a9b0c1d2e3f"
ENV["SECRET_KEY_BASE"] = SECRET

def build_context(cookie : String? = nil)
  headers = HTTP::Headers.new
  headers["Cookie"] = cookie if cookie
  request = HTTP::Request.new("GET", "/", headers)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  HTTP::Server::Context.new(request, response)
end

# set signed cookie like the controller does
ctx = build_context
jar = ActionController::Cookies.new(ctx)
jar.signed.set("session_token", "tok123",
  expires: Time.utc + 20.years, httponly: true, same_site: :lax)
line = ctx.response.headers.get("Set-Cookie").first
puts "set-cookie: #{line[0, 60]}..."

# now read it back in a fresh context (like the next request)
header = line.split(';').first
jar2 = ActionController::Cookies.new(build_context(header))
value = jar2.signed["session_token"]?
puts "read back: #{value.inspect} (class #{value.class})"

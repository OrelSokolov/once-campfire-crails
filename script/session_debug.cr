require "../src/app_boot_models"

s = Session.new({
  "user_id"        => 127326141_i64,
  "token"          => "testtoken",
  "user_agent"     => "curl",
  "ip_address"     => "127.0.0.1",
  "last_active_at" => Time.utc,
})
puts "attributes: #{s.attributes.keys.inspect}"
puts "last_active_at: #{s.last_active_at.inspect}"

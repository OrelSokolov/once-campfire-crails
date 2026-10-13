require "../src/app_boot_models"

v = Time.utc.as(ActiveRecord::Value)
puts "as?(Time): #{v.as?(Time).inspect}"
s = Session.new({"last_active_at" => Time.utc})
puts "direct attr: #{s.last_active_at.inspect}"
s2 = Session.new({"token" => "x"})
puts "token attr: #{s2.token.inspect}"

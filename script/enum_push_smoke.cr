# Разовый smoke: enum role + Push::Subscription validations (не компилируется
# в bin/app):   crystal run script/enum_push_smoke.cr
require "../src/app_boot_models"

# --- enum role ---
admin = User.where("role = 1").first!.not_nil!
puts "admin: role=#{admin.role.inspect} administrator?=#{admin.administrator?} bot?=#{admin.bot?} member?=#{admin.member?}"
raise "admin role getter" unless admin.role == "administrator"
raise "admin administrator?" unless admin.administrator? && !admin.bot? && !admin.member?

# Symbol/String в .new (active_record.cr v0.1.17)
u = User.new(name: "x", role: :bot, status: :active)
raise "new symbol role" unless u.role == "bot" && u.status == "active" && u.bot?
u2 = User.new(name: "x", role: "administrator")
raise "new string role" unless u2.administrator?
u3 = User.new(name: "x", role: 1_i64)
raise "new int role" unless u3.administrator?
u4 = User.new(name: "x") # default role из колонки (0)
raise "new default role" unless u4.member?
begin
  User.new(name: "x", role: "junk")
  raise "junk role did not raise"
rescue ArgumentError
  puts "junk role raises ArgumentError (ok)"
end

# --- Push::Subscription validations ---
sub = Push::Subscription.new(
  user_id: admin.id.not_nil!,
  endpoint: "https://web.push.apple.com/abc",
  p256dh_key: "k", auth_key: "a")
puts "push valid? (DNS for web.push.apple.com): #{sub.valid?}"
puts "  errors: #{sub.errors.map { |e| "#{e.attribute} #{e.message}" }}"
# DNS может не резолвиться в этой среде — оба исхода валидны, важно что не падает

bad = Push::Subscription.new(user_id: admin.id.not_nil!, endpoint: "http://fcm.googleapis.com/x")
raise "http endpoint must be invalid" unless !bad.valid?
msgs = bad.errors.map(&.message)
raise "expected must use HTTPS, got #{msgs}" unless msgs.includes?("must use HTTPS")
puts "http endpoint invalid: #{msgs.inspect}"

empty = Push::Subscription.new(user_id: admin.id.not_nil!, endpoint: "")
raise "empty endpoint must be invalid" unless !empty.valid?
raise "expected presence error" unless empty.errors.map(&.message).includes?("can't be blank")
puts "empty endpoint invalid: #{empty.errors.map { |e| "#{e.attribute} #{e.message}" }.inspect}"

host = Push::Subscription.new(user_id: admin.id.not_nil!, endpoint: "https://evil.example.com/x")
raise "non-permitted host must be invalid" unless !host.valid?
raise "expected permitted-host error" unless host.errors.map(&.message).includes?("is not a permitted push service")
puts "non-permitted host invalid (ok)"

puts "SMOKE OK"

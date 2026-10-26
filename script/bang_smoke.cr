# Smoke for bang-методов (plans/bang_methods.md):
#   crystal run script/bang_smoke.cr
# Проверяет id!/колоночные bang (ar_codegen), enum-reader bang,
# raise на unsaved/nil и Current.user! (CurrentAttributes).
require "../src/app_boot_models"

def expect_raises(message_part : String, &block)
  yield
  abort "FAIL: expected raise containing #{message_part.inspect}"
rescue e : NilAssertionError
  abort "FAIL: got #{e.message.inspect}, expected #{message_part.inspect}" unless e.message.to_s.includes?(message_part)
  puts "ok: raises #{e.message.inspect}"
end

david = User.where("email_address = ?", "david@37signals.com").first!
puts "id!        => #{david.id!}"
puts "room_id!   => #{Message.first!.room_id!}"
puts "creator_id!=> #{Message.first!.creator_id!}"
puts "role! (enum reader, String) => #{david.role!.inspect}"

# Unsaved record: id! must raise naming the model.
expect_raises("User#id is nil") { User.new.id! }

# Optional column nil: bang names model+column.
david.email_address = nil
expect_raises("User#email_address is nil") { david.email_address! }

# CurrentAttributes bang.
expect_raises("Nil assertion failed") { Current.user! }
Current.user = david
puts "Current.user! => #{Current.user!.name.inspect} (#{Current.user!.class})"
Current.reset
expect_raises("Nil assertion failed") { Current.user! }

puts "bang_smoke: OK"

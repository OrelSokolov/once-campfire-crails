# AR-профиль запросного пути на моделях приложения:
#   crystal run script/room_query_profile.cr
require "../src/app_boot_models"

def bench(label, n = 20_000, &)
  yield
  t = Time.monotonic
  n.times { yield }
  el = Time.monotonic - t
  printf("%-28s %7.2f µs/op\n", label, el.total_nanoseconds / 1000.0 / n)
end

david = User.where("email_address = ?", "david@37signals.com").first!
uid = david.id.not_nil!
rid = 486777696_i64

bench("Room.find?(rid)") { Room.find?(rid) }
bench("scope.where(id:).first") do
  Room.where("id IN (SELECT room_id FROM memberships WHERE user_id = ?)", uid)
    .where(id: rid).first
end
bench("scope str.where.first") do
  Room.where("id IN (SELECT room_id FROM memberships WHERE user_id = ?)", uid)
    .where("id = ?", rid).first
end
bench("Membership+find? (2 qry)") do
  if Membership.where("user_id = ? AND room_id = ?", uid, rid).first?
    Room.find?(rid)
  end
end

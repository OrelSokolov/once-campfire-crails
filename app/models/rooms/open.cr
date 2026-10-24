require "../application_record"
# Rooms open to all users on the account. When a new user is added to the account, they're automatically granted membership.
class Rooms::Open < Room
  after_save_commit :grant_access_to_all_users

  private def grant_access_to_all_users : Nil
    # memberships.grant_to(User.active) — insert_all with the room's default
    # involvement ('mentions'), duplicates skipped. The port writes the short
    # STI type ('Open') on create, so the guard checks that spelling.
    return unless type_previously_changed?(to: "Open")
    now = Time.utc
    ActiveRecord::Base.connection.exec(
      "insert into memberships (room_id, user_id, involvement, connections, created_at, updated_at) " \
      "select ?, id, 'mentions', 0, ?, ? from users where status = 0 " \
      "on conflict do nothing",
      id.not_nil!, now, now)
  end
end

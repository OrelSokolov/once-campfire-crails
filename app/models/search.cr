require "./application_record"
class Search < ApplicationRecord
  belongs_to :user

  after_create :trim_recent_searches

  scope(:ordered) { order("updated_at DESC") }

  # user.searches.excluding(user.searches.ordered.limit(10)).destroy_all —
  # no callbacks on Search, so delete_all in one statement is equivalent.
  private def trim_recent_searches : Nil
    uid = user_id.not_nil!
    Search.where(
      "user_id = ? AND id NOT IN (SELECT id FROM searches WHERE user_id = ? ORDER BY updated_at DESC LIMIT 10)",
      uid, uid).delete_all
  end
end

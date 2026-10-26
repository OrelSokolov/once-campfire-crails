require "./application_record"
class Search < ApplicationRecord
  belongs_to :user

  after_create :trim_recent_searches

  scope(:ordered) { order("updated_at DESC") }

  private def trim_recent_searches : Nil
    u = user.not_nil!
    u.searches.excluding(u.searches.ordered.limit(10)).destroy_all
  end
end

require "./application_job"

class RemoveBannedContentJob < ApplicationJob
  serialized user: User

  def self.queue_kind : String
    "remove_banned_content"
  end

  def perform(user : User) : Nil
    user.remove_banned_content
  end
end

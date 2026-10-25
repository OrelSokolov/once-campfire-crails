require "../application_record"

class User
  module Bannable
    # Ban: bans from the user's session IPs (no blanks, uniq), delete sessions
    # (sign out), status banned. Content is removed asynchronously by the
    # remove_banned_content job — enqueued strictly after commit, like notify in
    # MessageCreator.
    def ban : Nil
      Campfire::WriteQueue.perform do
        ActiveRecord::Base.transaction do
          create_bans_from_sessions
          apply_ban
        end
      end
      # apply_ban of the reference: close_remote_connections — tear the banned
      # user's live sockets AFTER commit (a socket closed too early reconnects
      # and re-reads the still-live session).
      close_remote_connections
      RemoveBannedContentJob.perform_later(self)
    end

    def unban : Nil
      Campfire::WriteQueue.perform do
        ActiveRecord::Base.transaction do
          bans.delete_all
          active!
        end
      end
    end

    private def create_bans_from_sessions : Nil
      sessions.pluck(:ip_address).compact_blank.uniq.each do |ip|
        bans.create!({"ip_address" => ip})
      end
    end

    private def apply_ban : Nil
      sessions.delete_all
      banned!
    end
  end
  include Bannable
end

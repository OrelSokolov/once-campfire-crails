require "../application_record"

# Membership::Connectable (oracle membership/connectable.rb): presence
# bookkeeping — connections counter + connected_at TTL. Scopes :connected /
# :disconnected live in membership.cr (Crystal `scope` is class-body only).
class Membership
  module Connectable
    include ActiveSupport::Concern

    CONNECTION_TTL = 60.seconds

    class_methods do
      def disconnect_all : Nil
        connected.update_all({"connected_at" => nil, "connections" => 0_i64,
                              "updated_at" => Time.utc})
      end

      def connect(membership : Membership, connections : Int64) : Nil
        where(id: membership.id!).update_all(
          {"connections" => connections, "connected_at" => Time.utc, "unread_at" => nil})
      end
    end

    macro included
      extend_class_methods!
    end

    def connected? : Bool
      connected_at.try { |at| at >= Time.utc - Connectable::CONNECTION_TTL } ? true : false
    end

    def present : Nil
      self.class.connect(self, connected? ? (connections || 0_i64) + 1 : 1_i64)
    end

    def connected : Nil
      increment_connections
      touch("connected_at")
    end

    def disconnected : Nil
      decrement_connections
      update!({"connected_at" => nil}) if (connections || 0) < 1
    end

    def refresh_connection : Nil
      increment_connections unless connected?
      touch("connected_at")
    end

    def increment_connections : Nil
      if connected?
        increment!("connections")
        touch("updated_at")
      else
        update!({"connections" => 1_i64})
      end
    end

    def decrement_connections : Nil
      if connected?
        decrement!("connections")
        touch("updated_at")
      else
        update!({"connections" => 0_i64})
      end
    end
  end
  include Connectable
end

require "./application_record"
class Ban < ApplicationRecord
  belongs_to :user

  def self.banned?(ip_address : String?) : Bool
    return false unless ip = ip_address
    ActiveRecord::Base.connection.query_one?(
      "SELECT 1 FROM bans WHERE ip_address = ? LIMIT 1", ip, as: Int32) != nil
  end
end

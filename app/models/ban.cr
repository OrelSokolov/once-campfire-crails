require "./application_record"
class Ban < ApplicationRecord
  belongs_to :user

  def self.banned?(ip_address : String?) : Bool
    return false unless ip = ip_address
    where("ip_address = ?", ip).exists?
  end
end

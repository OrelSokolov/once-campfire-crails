require "./application_record"
class Search < ApplicationRecord
  belongs_to :user
end

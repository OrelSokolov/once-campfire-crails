# Abstract base for all models (oracle application_record.rb); `abstract?` makes
# the active_record_cr walker skip it when registering tables.
abstract class ApplicationRecord < ActiveRecord::Base
end

require "railties_cr"
require "active_record_cr"
require "bcrypt"

require "../config/application"
require "../app/models/**"
require "../app/controllers/**"
require "../config/routes"
require "../config/environments/development"
require "../config/environments/production"

if (url = ENV["DATABASE_URL"]?)
  ActiveRecord::Base.establish_connection(url)
elsif File.exists?("config/database.yml")
  ActiveRecord::Base.establish_connection_from_yaml(
    "config/database.yml", CRails.env.to_s.downcase)
end

CRails.application.initialize!
CRails.application.boot(ARGV)

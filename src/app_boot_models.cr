# Model-only boot for scripts: loads framework + models + database
# connection without booting the HTTP server (src/app.cr runs the server).
require "railties_cr"
require "active_record_cr"

require "../config/application"
require "../app/models/**"

if (url = ENV["DATABASE_URL"]?)
  ActiveRecord::Base.establish_connection(url)
elsif File.exists?("config/database.yml")
  ActiveRecord::Base.establish_connection_from_yaml(
    "config/database.yml", "development")
end

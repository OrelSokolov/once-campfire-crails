require "railties_cr"
require "active_record_cr"
require "bcrypt"
require "rqrcode_cr"
require "serverx"

require "../config/application"
require "../app/models/**"
require "../app/helpers/chat_layout"
require "../app/helpers/page_cache"
require "../app/helpers/identity_cache"
require "../app/helpers/cable_bus"
require "../app/helpers/write_queue"
require "../app/jobs/**"
require "../config/cable"
require "../app/channels/application_cable/channel"
require "../app/channels/application_cable/connection"
require "../app/channels/**"
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

# Обёртка приложения в HTTP::Handler (роутер + cable — внутри chain)
# для транспорта ServerX.
class ServerXAppHandler
  include HTTP::Handler

  def call(context)
    CRails.application.call(context)
  end
end

# Транспорт: CRAILS_TRANSPORT=serverx — ServerX (nginx-модель, буфер на
# соединение, offset-парсер, fork+SO_REUSEPORT воркеры через WEB_CONCURRENCY;
# upgrade/ActionCable поддержан транспортом). Иначе — stdlib HTTP::Server
# (TcpNodelayServer) в CRails.application.boot.
if {"", "serve"}.includes?(ARGV[0]? || "") && ENV["CRAILS_TRANSPORT"]? == "serverx"
  # harness передаёт порт через HTTP_PORT env (не -p)
  port = ENV["HTTP_PORT"]?.try(&.to_i?) || CRails.application.config.port
  host = CRails.application.config.host
  i = ARGV[0]? ? 1 : 0
  while i < ARGV.size
    case ARGV[i]
    when "-p", "--port" then port = ARGV[i + 1].to_i; i += 2
    when "-b", "--bind" then host = ARGV[i + 1]; i += 2
    else i += 1
    end
  end

  handler = ServerXAppHandler.new

  # Выполняется в каждом воркере (в fork-ребёнке при Cluster): унаследованные
  # sqlite-дескрипторы переоткрываем, middleware compose до listen.
  database_url = ENV["DATABASE_URL"]?
  worker_block = ->do
    if db_url = database_url
      ActiveRecord::Base.establish_connection(db_url)
    end
    Campfire::JobQueue.reset!
    Campfire::WriteQueue.reset!
    Campfire::JobQueue.start_worker
    # Шина кабеля между воркерами (cable-batch): порт приложения + 1000
    Campfire::CableBus.start(port + 1000)
    CRails.application.middleware_chain
    server = ServerX::AppServer.new(handler, host, port,
      read_timeout: 30.seconds, write_timeout: 30.seconds)
    server.listen
  end

  workers = ENV["WEB_CONCURRENCY"]?.try(&.to_i?) || 1
  if workers > 1
    ServerX::Cluster.run(host, port, workers, worker_block)
  else
    worker_block.call
  end
else
  # Inline job worker (уведомления/push/webhooks) — как у express-кластера:
  # воркер очереди живёт в тех же процессах, что и HTTP.
  Campfire::JobQueue.start_worker if {"", "serve"}.includes?(ARGV[0]? || "")
  CRails.application.boot(ARGV)
end

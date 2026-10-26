require "railties_cr"
require "active_record_cr"
require "bcrypt"
require "rqrcode_cr"
require "jbuilder_cr"
require "serverx"

require "../config/application"
require "../app/models/**"
require "../app/helpers/html_sanitizer"
require "../app/helpers/chat_layout"
require "../app/helpers/chat_erb"
require "../app/helpers/emoji_helper"
require "../app/helpers/translations_helper"
require "../app/helpers/avatar_cache"
require "../app/helpers/identity_cache"
require "../app/helpers/cable_bus"
require "../app/helpers/write_queue"
require "../app/helpers/application_helper"
require "../app/helpers/accounts_helper"
require "../app/helpers/clipboard_helper"
require "../app/helpers/custom_styles_helpers"
require "../app/helpers/boosts_helpers"
require "../app/helpers/bots_helpers"
require "../app/helpers/first_runs_helpers"
require "../app/helpers/joins_helpers"
require "../app/helpers/messages_helper"
require "../app/helpers/users/profiles_helper"
require "../app/helpers/push_subscriptions_helpers"
require "../app/helpers/rooms_helper"
require "../app/helpers/searches_helper"
require "../app/helpers/sessions_helpers"
require "../app/helpers/session_transfers_helpers"
require "../app/helpers/users/sidebar_helper"
require "../app/helpers/users/avatars_helper"
require "../app/helpers/users_helper"
require "../app/helpers/qr_code_helper"
require "../app/helpers/welcome_helpers"
require "../app/jobs/**"

# jbuilder-партиалы (compile-time регистрация — рантайм-подстановки
# файлов шаблоны Crystal себе позволить не так, как в Ruby; пути —
# относительно корня запуска crystal, как у compile_template).
# Партиалы — методы JbuilderTemplate без контекста контроллера:
# origin им недоступен, экшен-шаблон проставляет jb_origin.
class JbuilderTemplate
  # CRails::Routes::UrlHelpers cannot be included here directly: its
  # method_missing macro would shadow Jbuilder's `json.<key>` DSL. A
  # dedicated context resolves url helpers with jb_origin as the origin.
  class UrlContext
    include CRails::Routes::UrlHelpers

    def initialize(@jb_origin : String)
    end

    def origin : String
      @jb_origin
    end
  end

  # room_message_url(message.room, message) — url helper delegate for
  # partials (jbuilder context has no request); origin from jb_origin.
  def room_message_url(room : Room?, message : Message) : String
    UrlContext.new(jb_origin)
      .__crails_url_helper("room_message_url", [room, message], {} of Symbol => Nil)
  end

  # fresh_user_avatar_path/_url(user), fresh_account_logo_path(options) —
  # direct-route helpers (config/routes.cr) for partials.
  def fresh_user_avatar_path(user : User) : String
    UrlContext.new(jb_origin).fresh_user_avatar_path(user)
  end

  def fresh_user_avatar_url(user : User) : String
    UrlContext.new(jb_origin).fresh_user_avatar_url(user)
  end

  def fresh_account_logo_path(**opts) : String
    UrlContext.new(jb_origin).fresh_account_logo_path(**opts)
  end

  attr_accessor jb_origin : String = "http://localhost"

  compile_partials({
    "users/user"                 => {path: "app/views/users/_user.json.jbuilder",
                                    locals: {"user" => User}},
    "messages/message"           => {path: "app/views/messages/_message.json.jbuilder",
                                    locals: {"message" => Message}},
    "messages/boosts/boost"      => {path: "app/views/messages/boosts/_boost.json.jbuilder",
                                    locals: {"boost" => Boost}},
    "autocompletable/users/user" => {path: "app/views/autocompletable/users/_user.json.jbuilder",
                                    locals: {"user" => User}},
  })
end

require "../config/cable"
require "../app/channels/application_cable/channel"
require "../app/channels/application_cable/connection"
require "../app/channels/**"
require "../app/controllers/concerns/**"
require "../app/controllers/**"
require "../config/routes"
require "../config/environments/development"
require "../config/environments/production"

# Turbo.render_partial — рендер broadcast_*_to(partial:) по имени
# партиала (аналог ApplicationController.render(formats: [:html],
# partial:) Rails): рантайм-рендера по пути файла в Crystal нет,
# партиалы ChatERB скомпилированы на этапе сборки — диспетчер по имени.
Turbo.partial_renderer = ->(partial : String, locals : Hash(String, Turbo::RenderVal)) do
  case partial
  when "users/sidebars/rooms/direct"
    ChatERB.new.render(partial, {"membership" => locals["membership"].as(Membership)}).to_s
  else
    raise ArgumentError.new("Missing partial #{partial.inspect}")
  end
end

if (url = ENV["DATABASE_URL"]?)
  ActiveRecord::Base.establish_connection(url)
elsif File.exists?("config/database.yml")
  ActiveRecord::Base.establish_connection_from_yaml(
    "config/database.yml", CRails.env.to_s.downcase)
end

CRails.application.initialize!

# Dev-заметка про кластер: в многопоточной сборке (дефолт Crystal 1.21)
# Process.fork не компилируется, поэтому форк-кластер недоступен, пока
# приложение не собрано с -Dwithout_mt. Предупреждаем один раз при старте
# сервера, а не падаем/молчим.
{% unless flag?(:without_mt) %}
  if {"", "serve"}.includes?(ARGV[0]? || "") && CRails.env.development?
    STDERR.puts "\e[1;33mCluster mode is off:\e[0m \e[33mmultithreaded build cannot fork " \
                "(compile with \e[1m-Dwithout_mt\e[0m\e[33m and set CRAILS_TRANSPORT=serverx " \
                "for the fork/SO_REUSEPORT cluster) — running a single process\e[0m"
  end
{% end %}

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
  # Разделяемая страница с write-мьютексом — ДО форка: дети наследуют
  # маппинг и инициализированный мьютекс (см. WriteQueue.prepare_fork!).
  Campfire::WriteQueue.prepare_fork!
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

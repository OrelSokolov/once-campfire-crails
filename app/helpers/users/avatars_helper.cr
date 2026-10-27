# users/avatars (оракул: app/helpers/users/avatars_helper.rb): хелпер
# только выбирает цвет фона; разметку рисует шаблон
# app/views/users/avatars/show.svg.erb (компилируется в
# Users::AvatarsController — view-генератор автокомпилирует только
# .html.erb/.turbo_stream.erb/.json.jbuilder). Digest::CRC32 побайтово
# равен Ruby Zlib.crc32. avatar_tag порт живёт в ChatLayout/messages_erb/
# boosts_erb (снапшот-пути рендера сообщений без AR-записей).
require "digest/crc32"

module Users::AvatarsHelper
  include ActionController::Helper

  AVATAR_COLORS = {"#AF2E1B", "#CC6324", "#3B4B59", "#BFA07A", "#ED8008",
                   "#ED3F1C", "#BF1B1B", "#736B1E", "#D07B53", "#736356",
                   "#AD1D1D", "#BF7C2A", "#C09C6F", "#698F9C", "#7C956B",
                   "#5D618F", "#3B3633", "#67695E"}

  # Оракул: AVATAR_COLORS[Zlib.crc32(user.to_param) % AVATAR_COLORS.size].
  def avatar_background_color(user : User) : String
    AVATAR_COLORS[(Digest::CRC32.checksum(user.to_param) % AVATAR_COLORS.size).to_i]
  end
end

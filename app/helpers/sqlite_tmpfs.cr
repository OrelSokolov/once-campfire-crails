require "uri"

module Campfire
  # SQLite-базы приложения — только на tmpfs (RAM). На дисковых ФС этого
  # класса (ext4 при высоком заполнении) чекпоинты SQLite ловят журнальные
  # столлы (jbd2) в сотни миллисекунд, замораживающие write-воркеров —
  # молчаливая деградация вместо ошибки. Fail fast на старте в production:
  # ActiveSupport::Filesystem.tmpfs? проверяет носитель каталога БД.
  def self.require_sqlite_tmpfs!(path_or_url : String, env_name : String) : Nil
    return unless CRails.env.to_s.downcase == "production"
    path = path_or_url
    if path.starts_with?("sqlite3://")
      path = URI.parse(path).path.to_s
    end
    return if path.empty?
    dir = File.dirname(File.expand_path(path, Dir.current))
    unless ActiveSupport::Filesystem.tmpfs?(dir)
      raise Exception.new(
        "#{env_name}: SQLite-база должна лежать на tmpfs (RAM), каталог #{dir} — не tmpfs. " \
        "Перенесите данные в tmpfs (например /dev/shm) и перезапустите.")
    end
  end
end

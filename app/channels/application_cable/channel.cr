# База каналов (референс: ApplicationCable::Channel).
class ApplicationCable::Channel < ActionCable::Channel::Base
  # Id текущего пользователя из connection-identifier (порт хранит
  # identifiers строками; @connection типизирован ConnectionAPI, поэтому
  # сужение до конкретного Connection).
  def current_user_id : String?
    conn = @connection
    if conn.is_a?(ActionCable::Connection)
      conn.current_user
    end
  end
end

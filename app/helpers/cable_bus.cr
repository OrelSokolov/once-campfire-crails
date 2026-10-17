require "socket"

# Межворкерная шина кабеля для serverX Cluster (эквивалент cluster-IPC
# «cable-batch» у once-campfire-express): TCP-хаб на loopback, избираемый
# bind-конкуренцией — первый занявший порт становится хабом, остальные
# воркеры подключаются клиентами. Broadcast доставляется локально всегда,
# в шину — только пирам (отправитель себе доставил сам, хаб не эхит
# сообщение обратно отправителю). Хаб умирает вместе с воркером —
# клиенты переподключаются, bind-конкуренция выбирает нового хаба.
#
# Запись в сокет — ТОЛЬКО через выделенную writer-фиберу соединения
# (Channel(QUEUE_CAPACITY)): request-фиберы никогда не ждут сокет.
# Прямые записи из многих фибер в один сокет, помимо интерливинга
# частичных write(2), подвешивали запросы навсегда при потере wakeup-а
# готовности записи (наблюдали на post-нагрузке ~1 фибера на ~150k
# запросов: cb-loc-done есть, cb-relay-done нет, Send-Q сокета пуст).
# Переполнение очереди (пиры отстали на QUEUE_CAPACITY кадров) — сокет
# закрывается: отставший пи́р переподключается супервизором, живые
# продолжают работать; канал — только live-обновления, источник правды
# остаётся в БД.
module Campfire
  module CableBus
    QUEUE_CAPACITY = 1024

    # Сокет шины: очередь кадров + writer-фибера + флаг закрытия.
    class Connection
      getter socket : TCPSocket
      getter queue : Channel(Tuple(String, String))
      @closed = false

      def initialize(@socket)
        @queue = Channel(Tuple(String, String)).new(QUEUE_CAPACITY)
      end

      # Поставить кадр в очередь writer-фиберы. false — соединение
      # закрыто (переполнение/разрыв), вызывающий роняет пир.
      def send_frame(stream : String, payload : String) : Bool
        return false if @closed
        select
        when @queue.send({stream, payload})
          true
        else
          close
          false
        end
      end

      # Writer-фибера: единственный писатель сокета (нет интерливинга
      # кадров), полная запись кадра (учёт частичного write(2)).
      def start_writer : Nil
        spawn do
          loop do
            frame = @queue.receive?
            break unless frame
            stream, payload = frame
            begin
              CableBus.write_fully(@socket, CableBus.frame_bytes(stream, payload))
            rescue
              close
              break
            end
          end
        end
      end

      def close : Nil
        return if @closed
        @closed = true
        @socket.close rescue nil
        @queue.close
      end

      def closed? : Bool
        @closed
      end
    end

    @@hub : TCPServer?
    @@client : Connection?
    @@peers = [] of Connection

    def self.start(port : Int32) : Nil
      spawn { supervisor_loop(port) }
    end

    # ————— API —————

    # Отправить кадр в шину пирам (БЕЗ локальной доставки — её делает
    # Campfire.broadcast до вызова). No-op без поднятой шины. Никогда
    # не блокирует вызывающую фиберу дольше отправки в Channel.
    def self.relay(stream : String, payload : String) : Nil
      if (conn = @@client)
        @@client = nil unless conn.send_frame(stream, payload)
      elsif @@hub
        @@peers.dup.each do |peer|
          @@peers.delete(peer) unless peer.send_frame(stream, payload)
        end
      end
    end

    # ————— Внутреннее —————

    private def self.supervisor_loop(port : Int32) : Nil
      loop do
        begin
          server = TCPServer.new("127.0.0.1", port)
          @@hub = server
          @@client = nil
          hub_loop(server)
        rescue Socket::BindError
          begin
            conn = Connection.new(TCPSocket.new("127.0.0.1", port))
            @@client = conn
            @@hub = nil
            conn.start_writer
            client_loop(conn.socket)
          rescue
            sleep 0.3.seconds
          end
        rescue
          sleep 0.3.seconds
        end
        # Соединение с хабом оборвалось (writer закрыл сокет или хаб
        # умер) — переподключаемся (возможно, уже как новый хаб).
        (@@client).try(&.close)
        @@client = nil
      end
    end

    private def self.hub_loop(server : TCPServer) : Nil
      while (sock = server.accept?)
        peer = Connection.new(sock)
        @@peers << peer
        peer.start_writer
        spawn { hub_peer_loop(peer) }
      end
      @@peers.each(&.close)
      @@peers.clear
    end

    # Хаб: кадр от пира → рассылка всем остальным (отправителю не эхим).
    private def self.hub_peer_loop(peer : Connection) : Nil
      while (frame = read_frame(peer.socket))
        stream, payload = frame
        @@peers.dup.each do |other|
          next if other == peer
          @@peers.delete(other) unless other.send_frame(stream, payload)
        end
      end
      peer.close
      @@peers.delete(peer)
    end

    # Клиент: кадр от хаба → локальная доставка кабелем. Напрямую в
    # pubsub, НЕ через Server#broadcast (CampfireCable): тот ретранслирует
    # в шину — кадр, пришедший по шине, эхом ушла бы пирам (петля).
    private def self.client_loop(sock : TCPSocket) : Nil
      while (frame = read_frame(sock))
        stream, payload = frame
        Turbo.cable.pubsub.broadcast(stream, payload)
      end
    end

    def self.frame_bytes(stream : String, payload : String) : Bytes
      buf = IO::Memory.new
      buf.write_bytes(stream.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      buf.write(stream.to_slice)
      buf.write_bytes(payload.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      buf.write(payload.to_slice)
      buf.to_slice
    end

    def self.write_fully(io, slice : Bytes) : Nil
      until slice.empty?
        written = io.write(slice)
        raise IO::Error.new("short write") if written.nil? || written == 0
        slice += written
      end
      io.flush
    end

    private def self.read_frame(io) : Tuple(String, String)?
      len1 = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      stream_buf = Bytes.new(len1.to_i32)
      io.read_fully(stream_buf)
      len2 = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      payload_buf = Bytes.new(len2.to_i32)
      io.read_fully(payload_buf)
      {String.new(stream_buf), String.new(payload_buf)}
    rescue
      nil
    end
  end

  # Единая точка broadcast для app-кода: доставку делает CampfireCable
  # (локальный pubsub + ретрансляция воркерам через шину; см.
  # config/cable.cr) — relay здесь не дублируем, иначе пиры получили бы
  # кадр дважды.
  def self.broadcast(stream : String, frame : String) : Nil
    Turbo.cable.broadcast(stream, frame)
  end
end

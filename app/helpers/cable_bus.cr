require "socket"

# Межворкерная шина кабеля для serverX Cluster (эквивалент cluster-IPC
# «cable-batch» у once-campfire-express): TCP-хаб на loopback, избираемый
# bind-конкуренцией — первый занявший порт становится хабом, остальные
# воркеры подключаются клиентами. Broadcast доставляется локально всегда,
# в шину — только пирам (отправитель себе доставил сам, хаб не эхит
# сообщение обратно отправителю). Хаб умирает вместе с воркером —
# клиенты переподключаются, bind-конкуренция выбирает нового хаба.
module Campfire
  module CableBus
    @@hub : TCPServer?
    @@client : TCPSocket?
    @@peers = [] of TCPSocket

    def self.start(port : Int32) : Nil
      spawn { supervisor_loop(port) }
    end

    # ————— API —————

    # Отправить кадр в шину пирам (БЕЗ локальной доставки — её делает
    # Campfire.broadcast до вызова). No-op без поднятой шины.
    def self.relay(stream : String, payload : String) : Nil
      if (client = @@client)
        begin
          write_frame(client, stream, payload)
        rescue
          @@client = nil
        end
      elsif @@hub
        @@peers.dup.each do |peer|
          begin
            write_frame(peer, stream, payload)
          rescue
            @@peers.delete(peer)
          end
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
            client = TCPSocket.new("127.0.0.1", port)
            @@client = client
            @@hub = nil
            client_loop(client)
          rescue
            sleep 0.3.seconds
          end
        rescue
          sleep 0.3.seconds
        end
      end
    end

    private def self.hub_loop(server : TCPServer) : Nil
      while (sock = server.accept?)
        @@peers << sock
        spawn { hub_peer_loop(sock) }
      end
    end

    # Хаб: кадр от пира → рассылка всем остальным (отправителю не эхим).
    private def self.hub_peer_loop(sock : TCPSocket) : Nil
      while (frame = read_frame(sock))
        stream, payload = frame
        @@peers.dup.each do |peer|
          next if peer == sock
          begin
            write_frame(peer, stream, payload)
          rescue
            @@peers.delete(peer)
          end
        end
      end
      @@peers.delete(sock)
    end

    # Клиент: кадр от хаба → локальная доставка кабелем.
    private def self.client_loop(sock : TCPSocket) : Nil
      while (frame = read_frame(sock))
        stream, payload = frame
        Turbo.cable.broadcast(stream, payload)
      end
    end

    private def self.write_frame(io, stream : String, payload : String) : Nil
      buf = IO::Memory.new
      buf.write_bytes(stream.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      buf.write(stream.to_slice)
      buf.write_bytes(payload.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      buf.write(payload.to_slice)
      io.write(buf.to_slice)
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

  # Единая точка broadcast: локальная доставка кабелем этого воркера +
  # ретрансляция остальным воркерам через шину (serverX Cluster).
  def self.broadcast(stream : String, frame : String) : Nil
    Turbo.cable.broadcast(stream, frame)
    CableBus.relay(stream, frame)
  end
end

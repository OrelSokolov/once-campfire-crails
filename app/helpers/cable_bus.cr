require "socket"

# Inter-worker cable bus for serverX Cluster: a TCP hub on loopback elected by
# a bind race — the first worker to take the port becomes the hub, the others
# connect as clients. Broadcast is always delivered locally; only peers get it
# over the bus (the sender already delivered locally, the hub does not echo a
# frame back to its sender). The hub dies with its worker — clients reconnect
# and the bind race elects a new hub.
#
# Socket writes MUST go through the connection's dedicated writer fiber
# (Channel(QUEUE_CAPACITY)): request fibers never wait on the socket. Direct
# writes from many fibers into one socket, besides interleaving partial
# write(2)s, hung requests forever when a write-readiness wakeup was lost
# (observed under post load, ~1 fiber per ~150k requests). On queue overflow
# (peers lagging by QUEUE_CAPACITY frames) the socket is closed: the lagging
# peer reconnects via its supervisor, live peers keep going; the channel
# carries live updates only — the DB remains the source of truth.
module Campfire
  module CableBus
    QUEUE_CAPACITY = 1024

    # Bus connection: frame queue + writer fiber + closed flag.
    class Connection
      attr_reader socket : TCPSocket
      attr_reader queue : Channel(Tuple(String, String))
      @closed = false

      def initialize(@socket)
        @queue = Channel(Tuple(String, String)).new(QUEUE_CAPACITY)
      end

      # Enqueue a frame for the writer fiber; false means the connection is
      # closed (overflow/teardown) and the caller drops the peer.
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

      # Writer fiber: the only socket writer (no frame interleaving), writes
      # each frame fully (accounts for partial write(2)).
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

    # Send a frame to peers over the bus (NO local delivery — Campfire.broadcast
    # does that before the call). No-op without a live bus; never blocks the
    # calling fiber longer than the Channel send.
    def self.relay(stream : String, payload : String) : Nil
      if (conn = @@client)
        @@client = nil unless conn.send_frame(stream, payload)
      elsif @@hub
        @@peers.dup.each do |peer|
          @@peers.delete(peer) unless peer.send_frame(stream, payload)
        end
      end
    end

    # ————— Internal —————

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
        # Hub connection lost (writer closed the socket or the hub died) —
        # reconnect, possibly as the new hub.
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

    # Hub: frame from a peer is fanned out to every other peer (no echo to sender).
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

    # Client: frame from the hub is delivered to the cable directly through
    # pubsub, NOT via Server#broadcast (CampfireCable): that one relays into
    # the bus — a frame arriving over the bus would echo back to peers (loop).
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

  # Single broadcast entry point for app code: delivery is CampfireCable's job
  # (local pubsub + relay to workers over the bus; see config/cable.cr) — no
  # relay here, or peers would receive every frame twice.
  def self.broadcast(stream : String, frame : String) : Nil
    Turbo.cable.broadcast(stream, frame)
  end
end

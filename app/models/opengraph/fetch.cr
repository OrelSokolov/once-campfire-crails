# fetch.rb: GET/HEAD с редиректами (лимит 10), общим дедлайном
# (остаток бюджета на каждый connect/read/write, максимум TIMEOUT —
# как 7.seconds у Rails) и лимитом тела 5MB.
class Opengraph::Fetch
  MAX_REDIRECTS = 10
  MAX_BODY_SIZE = 5 * 1024 * 1024 # 5.megabytes
  TIMEOUT = 7.0
  REDIRECT_STATUSES = {301, 302, 303, 307, 308}

  def self.fetch_document(url : URI, deadline : Time::Instant? = nil) : String?
    request(url, :get, deadline) do |response|
      next nil unless response.status_code == 200
      next nil unless media_type(response) == "text/html"
      if length = response.headers["Content-Length"]?
        next nil if (length.to_i64? || 0) > MAX_BODY_SIZE
      end
      body = IO::Memory.new
      chunk = Bytes.new(8192)
      while (n = response.body_io.read(chunk)) > 0
        return nil if body.bytesize + n > MAX_BODY_SIZE
        body.write(chunk[0, n])
      end
      body.to_s
    end
  end

  def self.fetch_content_type(url : URI, deadline : Time::Instant? = nil) : String?
    request(url, :head, deadline) do |response|
      response.headers["Content-Type"]?
    end
  end

  private def self.media_type(response) : String
    response.headers["Content-Type"]?.to_s.split(';').first?.to_s.strip.downcase
  end

  private def self.request(url : URI, method : Symbol, deadline : Time::Instant?)
    current = url
    redirects = 0
    loop do
      return nil unless {"http", "https"}.includes?(current.scheme.to_s)
      return nil if current.user || current.password
      host = current.host
      return nil unless host && !host.empty?

      remaining = deadline ? deadline - Time.instant : nil
      return nil if remaining && remaining.total_seconds <= 0
      timeout = remaining ? {remaining, TIMEOUT.seconds}.min : TIMEOUT.seconds

      tls = current.scheme == "https"
      port = current.port || (tls ? 443 : 80)
      # DNS-пиннинг (restricted_http оракула): один резолв на hop —
      # все адреса обязаны быть публичными, соединение открывается к
      # проверенному IP. Повторного резолва внутри HTTP::Client нет,
      # значит DNS-rebinding (валидация → публичный, коннект →
      # приватный) закрыт; TLS: SNI/верификация по имени хоста.
      begin
        addrs = Socket::Addrinfo.resolve(host, port, type: Socket::Type::STREAM)
      rescue ex
        return nil
      end
      return nil if addrs.empty? ||
                    !addrs.all? { |a| Opengraph.public_ip?(a.ip_address.address) }
      ip = addrs.first.ip_address.address

      begin
        socket = TCPSocket.new(ip, port, connect_timeout: timeout.total_seconds)
      rescue ex
        return nil
      end
      begin
        socket.read_timeout = timeout.total_seconds
        socket.write_timeout = timeout.total_seconds
        client = if tls
          context = OpenSSL::SSL::Context::Client.new
          tls_socket = OpenSSL::SSL::Socket::Client.new(socket,
            context: context, sync_close: true, hostname: host)
          HTTP::Client.new(tls_socket, host, port)
        else
          HTTP::Client.new(socket, host, port)
        end
      rescue ex
        socket.close rescue nil
        return nil
      end

      path = current.request_target
      result = nil : String?
      redirect_to : URI? = nil
      begin
        client.exec(method == :head ? "HEAD" : "GET", path) do |response|
          if REDIRECT_STATUSES.includes?(response.status_code) &&
             (location = response.headers["Location"]?)
            redirect_to = current.resolve(URI.parse(location))
          else
            result = yield response
          end
        end
      ensure
        client.close
      end
      return result unless result.nil?
      if next_url = redirect_to
        redirects += 1
        return nil if redirects >= MAX_REDIRECTS
        current = next_url
      else
        return nil
      end
    end
  end
end

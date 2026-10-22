require "http/client"
require "xml"

# Порт once-campfire/app/models/opengraph/*.rb: unfurl вставленной
# ссылки — HTTP-клиент с private-network-guard'ом (fetch.rb/location.rb),
# парсер og-тегов (document.rb) и Metadata с валидацией (metadata.rb +
# metadata/fetching.rb, включая fxtwitter-подмену для twitter/x.com).
#
# Отклонения от Rails-оракула: restricted_http-гем заменён DNS-резолвом
# с пиннингом соединения (все адреса хоста обязаны быть публичными,
# fail closed; коннект — к проверенному IP, TLS/SNI — по имени хоста);
# санитайз — decode-entities + strip-tags вместо Loofah. JSON-контракт —
# express opengraph.js.
module Opengraph
  # express opengraph.js publicAddress: публичный IPv4/IPv6?
  # (fail closed: всё, что не глобально-уникальный адрес — приватно).
  def self.public_ip?(address : String) : Bool
    unless address.includes?(':')
      # IPv4
      parts = address.split('.')
      return false unless parts.size == 4
      octets = parts.map(&.to_i?)
      return false if octets.any?(&.nil?)
      a = octets[0].not_nil!
      b = octets[1].not_nil!
      return false if a == 0 || a == 10 || a == 127 || a >= 224
      return false if a == 169 && b == 254                  # link-local
      return false if a == 172 && b >= 16 && b <= 31        # 172.16/12
      return false if a == 192 && (b == 168 || b == 0)      # 192.168, 192.0
      return false if a == 100 && b >= 64 && b <= 127       # CGNAT
      return false if a == 198 && (b == 18 || b == 19)      # benchmark
      return false if a == 198 && b == 51                   # TEST-NET-2
      return false if a == 203 && b == 0                    # TEST-NET-3
      true
    else
      # IPv6: только global unicast (2xxx/3xxx); mapped/special-use
      # не начинаются с 2/3 — fail closed.
      ip = address.downcase
      (ip.starts_with?('2') || ip.starts_with?('3')) &&
        !ip.starts_with?("2001:db8:") && !ip.starts_with?("2001:0") && !ip.starts_with?("2002:")
    end
  end

  # DNS-резолв хоста: публичен, если это литерал-IP или ВСЕ адреса
  # резолва публичны (express resolvePublic; пустой резолв — приватен).
  def self.public_host?(host : String) : Bool
    literal = host.starts_with?('[') ? host[1..-2] : host
    return public_ip?(literal) if literal.matches?(/\A\d+\.\d+\.\d+\.\d+\z/) ||
                                  literal.includes?(':')
    # type: STREAM обязателен: nil-дефолт параметра в stdlib 1.21
    # не инстанцируется (can't restrict Nil to Type).
    addrs = Socket::Addrinfo.resolve(literal, 80,
      type: Socket::Type::STREAM) rescue return false
    return false if addrs.empty?
    addrs.all? { |a| public_ip?(a.ip_address.address) }
  end

  # location.rb: валидация URL (http/https, без userinfo — express
  # resolvePublic, надмножество URI::HTTP-проверки Rails) + публичность.
  class Location
    FILES_AND_MEDIA_URL_REGEX =
      /\bhttps?:\/\/\S+\.(?:zip|tar|tar\.gz|tar\.bz2|tar\.xz|gz|bz2|rar|7z|dmg|exe|msi|pkg|deb|iso|jpg|jpeg|png|gif|bmp|mp4|mov|avi|mkv|wmv|flv|heic|heif|mp3|wav|ogg|aac|wma|webm|ogv|mpg|mpeg)\b/

    def initialize(@url : String)
    end

    def valid? : Bool
      parsed = parse
      return false unless parsed
      return false unless {"http", "https"}.includes?(parsed.scheme.to_s)
      host = parsed.host
      return false unless host && !host.empty?
      return false if parsed.user || parsed.password
      Opengraph.public_host?(host)
    end

    # read_html: nil для невалидного/медиа-URL и при ошибке сети.
    def read_html(deadline : Time::Instant? = nil) : String?
      return nil unless valid?
      return nil if FILES_AND_MEDIA_URL_REGEX.match(@url)
      Fetch.fetch_document(parse.not_nil!, deadline)
    rescue ex
      nil
    end

    def fetch_content_type(deadline : Time::Instant? = nil) : String?
      return nil unless valid?
      Fetch.fetch_content_type(parse.not_nil!, deadline)
    rescue ex
      nil
    end

    private def parse : URI?
      @parsed_url ||= URI.parse(@url)
    rescue ex
      @parsed_url = nil
    end

    @parsed_url : URI?
  end

  # fetch.rb: GET/HEAD с редиректами (лимит 10), общим дедлайном
  # (остаток бюджета на каждый connect/read/write, максимум TIMEOUT —
  # как 7.seconds у Rails) и лимитом тела 5MB.
  class Fetch
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

  # document.rb: og-теги из HTML. Дубликаты — последний выигрывает
  # (Rails Hash[tag-массив]), посторонние og-ключи срезаются до
  # ATTRIBUTES (title, url, image, description); невалидный HTML →
  # пустой результат.
  class Document
    ATTRIBUTE_NAMES = %w(title url image description)

    def initialize(html : String?)
      @html = html
    end

    def opengraph_attributes : Hash(String, String)
      attributes = {} of String => String
      document = XML.parse_html((@html.to_s).scrub) rescue return attributes
      document.xpath_nodes("//meta").each do |tag|
        key = tag["property"]? || tag["name"]?
        content = tag["content"]?
        next unless key && content && !content.empty?
        next unless key.starts_with?("og:")
        name = key[3..]
        attributes[name] = content if ATTRIBUTE_NAMES.includes?(name)
      end
      attributes
    end
  end

  # metadata.rb + metadata/fetching.rb.
  class Metadata
    TWITTER_HOSTS = %w(twitter.com www.twitter.com x.com www.x.com)
    FX_TWITTER_HOST = "fxtwitter.com"
    ALLOWED_IMAGE_CONTENT_TYPES = %w(image/jpeg image/png image/gif image/webp)

    property title : String? = nil
    property url : String? = nil
    property image : String? = nil
    property description : String? = nil

    def self.from_url(url : String, deadline : Time::Instant? = nil) : self
      attributes = fetch_document(url, deadline).opengraph_attributes
      metadata = new
      metadata.title = sanitize(attributes["title"]?)
      metadata.description = sanitize(attributes["description"]?)
      metadata.url = valid_canonical_url(attributes["url"]?, url)
      metadata.image = valid_image_content_type(attributes["image"]?, deadline)
      metadata
    end

    # metadata.rb: validates_presence_of :title, :url, :description
    # (image опционален).
    def valid? : Bool
      !title.to_s.empty? && !url.to_s.empty? && !description.to_s.empty?
    end

    def to_json(io : IO) : Nil
      JSON.build(io) do |json|
        json.object do
          json.field "title", title
          json.field "url", url
          json.field "image", image
          json.field "description", description
        end
      end
    end

    def self.fetch_document(url : String, deadline : Time::Instant?) : Document
      target = tweet_url?(url) ? replace_twitter_domain(url) : url
      Document.new(Opengraph::Location.new(target).read_html(deadline))
    end

    def self.valid_canonical_url(url : String?, fallback : String) : String?
      return fallback unless url
      Opengraph::Location.new(url).valid? ? url : fallback
    end

    def self.valid_image_content_type(image : String?, deadline : Time::Instant?) : String?
      return nil unless image && !image.empty?
      content_type = Opengraph::Location.new(image)
        .fetch_content_type(deadline)
        .try(&.downcase)
      if content_type && ALLOWED_IMAGE_CONTENT_TYPES.includes?(content_type)
        image
      else
        nil
      end
    rescue ex
      nil
    end

    # Twitter.com/X.com не отдают og-теги — подменяем домен на
    # fxtwitter.com (fetching.rb).
    def self.replace_twitter_domain(url : String) : String
      uri = URI.parse(url)
      uri.host = FX_TWITTER_HOST if (host = uri.host) && TWITTER_HOSTS.includes?(host)
      uri.to_s
    rescue ex
      url
    end

    def self.tweet_url?(url : String) : Bool
      uri = URI.parse(url)
      path = uri.path.to_s
      return false unless host = uri.host
      TWITTER_HOSTS.includes?(host) && !path.empty? && path != "/"
    rescue ex
      false
    end

    # sanitize(strip_tags(...)): декодируем entities (Rails-тест
    # "&#x3c;img...&#x3e;" → тег снимается), снимаем теги; пустое → nil.
    # Декод — циклом Regex#match (gsub-блок с группами в Crystal 1.21
    # возвращает мусорные MatchData#[]).
    ENTITY_REGEX = /&#(x[0-9a-fA-F]+|\d+);/

    def self.sanitize(content : String?) : String?
      return nil unless content
      decoded = decode_entities(content)
        .gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">")
        .gsub("&quot;", "\"").gsub("&apos;", "'").gsub("&#39;", "'")
      stripped = decoded.gsub(/<[^>]*>/, "")
      stripped.empty? ? nil : stripped
    end

    private def self.decode_entities(content : String) : String
      out = String::Builder.new
      pos = 0
      while match = ENTITY_REGEX.match(content, pos)
        match_begin = match.begin.not_nil!
        match_end = match.end.not_nil!
        out << content[pos...match_begin]
        replacement = entity_char(entity_codepoint(match[1].not_nil!))
        out << (replacement || content[match_begin...match_end])
        pos = match_end
      end
      out << content[pos..] if pos < content.bytesize
      out.to_s
    end

    # "x3c" (hex) | "60" (dec) → кодовая точка; иначе nil.
    private def self.entity_codepoint(token : String) : Int64?
      if token.starts_with?('x')
        token[1..].to_i64?(16)
      else
        token.to_i64?
      end
    end

    private def self.entity_char(codepoint : Int64?) : String?
      return nil unless codepoint && codepoint > 0 && codepoint <= 0xD7FF
      codepoint.chr.to_s
    rescue ex
      nil
    end
  end
end

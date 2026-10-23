# location.rb: валидация URL (http/https, без userinfo — express
# resolvePublic, надмножество URI::HTTP-проверки Rails) + публичность.
class Opengraph::Location
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
    Opengraph::Fetch.fetch_document(parse.not_nil!, deadline)
  rescue ex
    nil
  end

  def fetch_content_type(deadline : Time::Instant? = nil) : String?
    return nil unless valid?
    Opengraph::Fetch.fetch_content_type(parse.not_nil!, deadline)
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

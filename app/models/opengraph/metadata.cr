class Opengraph::Metadata
  TWITTER_HOSTS = %w(twitter.com www.twitter.com x.com www.x.com)
  FX_TWITTER_HOST = "fxtwitter.com"
  ALLOWED_IMAGE_CONTENT_TYPES = %w(image/jpeg image/png image/gif image/webp)

  property title : String? = nil
  property url : String? = nil
  property image : String? = nil
  property description : String? = nil

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

  # sanitize(strip_tags(...)): decode entities (a Rails test expects "&#x3c;img...&#x3e;" to strip the tag),
  # then strip tags; empty → nil. Decoding uses a Regex#match loop — a gsub block with groups returns
  # garbage MatchData#[] on Crystal 1.21.
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

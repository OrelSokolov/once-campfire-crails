class Opengraph::Metadata
  module Fetching
    def from_url(url : String, deadline : Time::Instant? = nil) : Metadata
      attributes = fetch_document(url, deadline).opengraph_attributes
      metadata = Metadata.new
      metadata.title = Metadata.sanitize(attributes["title"]?)
      metadata.description = Metadata.sanitize(attributes["description"]?)
      metadata.url = valid_canonical_url(attributes["url"]?, url)
      metadata.image = valid_image_content_type(attributes["image"]?, deadline)
      metadata
    end

    def fetch_document(url : String, deadline : Time::Instant?) : Opengraph::Document
      target = tweet_url?(url) ? replace_twitter_domain(url) : url
      Opengraph::Document.new(Opengraph::Location.new(target).read_html(deadline))
    end

    def valid_canonical_url(url : String?, fallback : String) : String?
      return fallback unless url
      Opengraph::Location.new(url).valid? ? url : fallback
    end

    def valid_image_content_type(image : String?, deadline : Time::Instant?) : String?
      return nil unless image && !image.empty?
      content_type = Opengraph::Location.new(image)
        .fetch_content_type(deadline)
        .try(&.downcase)
      if content_type && Metadata::ALLOWED_IMAGE_CONTENT_TYPES.includes?(content_type)
        image
      else
        nil
      end
    rescue ex
      nil
    end

    # Twitter.com and X.com do not support Opengraph at the moment.
    # Piggybacking on fxtwitter.com allows us to have twitter unfurling
    # without relying on fxtwitter.com's future availability.
    def replace_twitter_domain(url : String) : String
      uri = URI.parse(url)
      uri.host = Metadata::FX_TWITTER_HOST if (host = uri.host) && Metadata::TWITTER_HOSTS.includes?(host)
      uri.to_s
    rescue ex
      url
    end

    def tweet_url?(url : String) : Bool
      uri = URI.parse(url)
      path = uri.path.to_s
      return false unless host = uri.host
      Metadata::TWITTER_HOSTS.includes?(host) && !path.empty? && path != "/"
    rescue ex
      false
    end
  end

  extend Fetching
end

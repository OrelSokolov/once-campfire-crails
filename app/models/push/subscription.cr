require "../application_record"
require "../../jobs/web_push"

# Web Push browser subscription: push-service endpoint + p256dh/auth keys.
# Endpoint validation uses a plain DNS public-IP check instead of the
# reference's restricted_http PrivateNetworkGuard.
class Push::Subscription < ApplicationRecord
  set_table_name "push_subscriptions"
  belongs_to :user

  PERMITTED_ENDPOINT_HOSTS = %w[
    jmt17.google.com
    fcm.googleapis.com
    updates.push.services.mozilla.com
    web.push.apple.com
    notify.windows.com
  ]

  validates :endpoint, presence: true
  validate :validate_endpoint_url

  private def endpoint_uri : URI?
    URI.parse(endpoint.to_s)
  rescue URI::Error | ArgumentError
    nil
  end

  private def validate_endpoint_url : Nil
    uri = endpoint_uri
    if uri.nil?
      errors.add("endpoint", "is not a valid URL")
    elsif uri.scheme != "https"
      errors.add("endpoint", "must use HTTPS")
    elsif !(uri.port.nil? || uri.port == 443)
      errors.add("endpoint", "must use the default HTTPS port")
    elsif !permitted_endpoint_host?
      errors.add("endpoint", "is not a permitted push service")
    elsif !resolves_to_public_ip?
      errors.add("endpoint", "resolves to a private or invalid IP address")
    end
  end

  private def permitted_endpoint_host? : Bool
    host = endpoint_uri.try(&.host).to_s.downcase
    return false if host.empty?
    PERMITTED_ENDPOINT_HOSTS.any? do |permitted|
      host == permitted || host.ends_with?(".#{permitted}")
    end
  end

  # Simplified PrivateNetworkGuard: every A/AAAA address of the host must be public;
  # nil on a private/special address or resolve failure — fail closed.
  private def resolves_to_public_ip? : Bool
    return false unless uri = endpoint_uri
    Campfire::WebPush.resolve_public(uri) != nil
  rescue Socket::Error | ArgumentError
    false
  end
end

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

  # Endpoint must be present and pass current validations — the reference re-validates
  # existing endpoints on create too ("Existing endpoints must pass current validations").
  def valid_subscription? : Bool
    !endpoint.to_s.empty? && endpoint_error.nil?
  end

  # The reference's errors.add(:endpoint, ...) message text, or nil.
  def endpoint_error : String?
    uri = endpoint_uri
    return "is not a valid URL" unless uri
    return "must use HTTPS" unless uri.scheme == "https"
    return "must use the default HTTPS port" unless uri.port.nil? || uri.port == 443
    return "is not a permitted push service" unless permitted_endpoint_host?
    return "resolves to a private or invalid IP address" unless resolves_to_public_ip?
    nil
  end

  private def endpoint_uri : URI?
    URI.parse(endpoint.to_s)
  rescue URI::Error | ArgumentError
    nil
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

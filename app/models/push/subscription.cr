require "../application_record"
require "../../jobs/web_push"

# Push::Subscription референса (push/subscription.rb): подписка браузера
# на Web Push — endpoint push-сервиса + ключи шифрования p256dh/auth,
# user_agent регистрации. Валидация endpoint (validate_endpoint_url):
# presence, https, порт 443 (дефолтный), whitelist хостов push-сервисов,
# DNS-резолв без приватных адресов (rebinding-guard; у референса —
# restricted_http PrivateNetworkGuard, здесь — DNS-проверка без
# пиннинга, как WebPush.resolve_public — см. PLAN_REMAINING §2).
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

  # valid? Rails: endpoint задан и проходит все проверки URL. Вызывается
  # и для существующих подписок — create референса при совпадении
  # endpoint-тройки требует повторную валидацию («Existing endpoints
  # must pass current validations»).
  def valid_subscription? : Bool
    !endpoint.to_s.empty? && endpoint_error.nil?
  end

  # errors.add(:endpoint, …) референса — текст ошибки или nil.
  def endpoint_error : String?
    uri = endpoint_uri
    return "is not a valid URL" unless uri
    return "must use HTTPS" unless uri.scheme == "https"
    return "must use the default HTTPS port" unless uri.port.nil? || uri.port == 443
    return "is not a permitted push service" unless permitted_endpoint_host?
    return "resolves to a private or invalid IP address" unless resolves_to_public_ip?
    nil
  end

  # ————— Частные проверки (private у референса) —————

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

  # resolved_endpoint_ip: все A/AAAA-адреса хоста должны быть публичными
  # (упрощённый PrivateNetworkGuard; resolve_public возвращает nil при
  # приватном/специальном адресе или ошибке резолва — fail closed).
  private def resolves_to_public_ip? : Bool
    return false unless uri = endpoint_uri
    Campfire::WebPush.resolve_public(uri) != nil
  rescue Socket::Error | ArgumentError
    false
  end
end

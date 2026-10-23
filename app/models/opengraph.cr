require "http/client"
require "xml"

# opengraph/*.cr — unfurl вставленной ссылки (порт
# once-campfire/app/models/opengraph/*.rb): location/fetch/document/
# metadata + metadata/fetching.
#
# Отклонение от Rails-оракула: restricted_http-гем заменён DNS-резолвом
# с пиннингом соединения (все адреса хоста обязаны быть публичными,
# fail closed; коннект — к проверенному IP, TLS/SNI — по имени хоста).
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
end

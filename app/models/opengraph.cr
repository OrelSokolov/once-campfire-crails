require "http/client"
require "xml"

# Port of the Rails opengraph models (location/fetch/document/metadata + metadata/fetching).
# Deviation from the Rails oracle: the restricted_http gem is replaced by DNS resolution with
# connection pinning (all of a host's addresses must be public, fail closed; connect to the
# verified IP, TLS/SNI by hostname).
module Opengraph
  # express opengraph.js publicAddress: public IPv4/IPv6? (fail closed: anything not globally unique is private).
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
      # IPv6: global unicast only (2xxx/3xxx); mapped/special-use don't start with 2/3 — fail closed.
      ip = address.downcase
      (ip.starts_with?('2') || ip.starts_with?('3')) &&
        !ip.starts_with?("2001:db8:") && !ip.starts_with?("2001:0") && !ip.starts_with?("2002:")
    end
  end

  # A host is public if it's an IP literal or ALL resolved addresses are public (empty resolution is private).
  def self.public_host?(host : String) : Bool
    literal = host.starts_with?('[') ? host[1..-2] : host
    return public_ip?(literal) if literal.matches?(/\A\d+\.\d+\.\d+\.\d+\z/) ||
                                  literal.includes?(':')
    # type: STREAM is required: the parameter's nil default doesn't instantiate on the Crystal 1.21 stdlib.
    addrs = Socket::Addrinfo.resolve(literal, 80,
      type: Socket::Type::STREAM) rescue return false
    return false if addrs.empty?
    addrs.all? { |a| public_ip?(a.ip_address.address) }
  end
end

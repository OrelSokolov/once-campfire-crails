# frozen_string_literal: true

require "base64"

module Parity
  # HTML normalization for cross-target comparison: strips per-run noise
  # (CSRF tokens, base URL, relative-time wording). Keeps structure, classes,
  # ids, signed tokens (deterministic under the shared secret) and seed content.
  module Normalize
    module_function

    def html(html, base_url)
      out = html.gsub(base_url, "__BASE__")
      out.gsub!(%r{(<meta name="csrf-token" content=")[^"]*(")}) { Regexp.last_match(1) + "__CSRF__" + Regexp.last_match(2) }
      out.gsub!(%r{(<input[^>]*name="authenticity_token"[^>]*value=")[^"]*(")}) { Regexp.last_match(1) + "__CSRF__" + Regexp.last_match(2) }
      out.gsub!(%r{(<time\b[^>]*>)[^<]*(</time>)}) { Regexp.last_match(1) + "__TIME__" + Regexp.last_match(2) }
      # Wall-clock noise: messages created during the run carry real
      # timestamps that can never match across runs or targets.
      out.gsub!(%r{(\bdatetime=")[^"]*(")}) { Regexp.last_match(1) + "__TIME__" + Regexp.last_match(2) }
      out.gsub!(%r{(\btitle=")(\d{2}/\d{2}/\d{2}, \d{1,2}:\d{2} [AP]M)(")}) { Regexp.last_match(1) + "__TIME__" + Regexp.last_match(3) }
      out.gsub!(%r{(\bdata-(?:message-timestamp|message-updated-at|sort-value|refresh-room-loaded-at-value)=")[^"]*(")}) do
        Regexp.last_match(1) + "__EPOCH__" + Regexp.last_match(2)
      end
      # Per-run random ids generated client-side: composer client_message_id
      # (message_<random>, edit_/boosting_/new_boost_/boosts_message_<random>)
      # and the lexxy editor link-input id suffix. Client ids are ~11 chars
      # mixed alnum; keep short/numeric tokens (message_id, message_body,
      # message_933434505) intact.
      out.gsub!(%r{(lexxy-link-url-)[a-z0-9]+}) { Regexp.last_match(1) + "__RAND__" }
      # Per-run client ids of messages posted during the run (each target's
      # composer generates its own random id at POST time) — can never match
      # across targets. Seeded messages carry fixed ids equal on both sides,
      # so masking them too changes nothing.
      out.gsub!(%r{(data-client-message-id=")[a-z0-9-]{8,}(")}) { Regexp.last_match(1) + "__CID__" + Regexp.last_match(2) }
      out.gsub!(%r{((?:edit_|boosting_|new_boost_|boosts_)?message_)([a-z0-9]+(?:-[a-z0-9]+)*)}) do
        prefix, token = Regexp.last_match(1), Regexp.last_match(2)
        token.length >= 6 && token.match?(/[a-z]/) ? prefix + "__CID__" : Regexp.last_match(0)
      end
      # Roving tabindex reacts to focus — inherently racy.
      out.gsub!(%r{\s+tabindex="-1"}, "")
      out.gsub!(%r{(name="message\[client_message_id\]"[^>]*value=")[^"]*(")}) { Regexp.last_match(1) + "__CID__" + Regexp.last_match(2) }
      # QR codes encode the full join/transfer URL — host:port and the
      # wall-clock expiry inside transfer tokens vary per run.
      out.gsub!(%r{/qr_code/([A-Za-z0-9+/=]+)}) do
        blob = Regexp.last_match(1)
        decoded = (Base64.strict_decode64(blob) rescue nil)
        next Regexp.last_match(0) unless decoded

        decoded = decoded.gsub(base_url, "__BASE__")
                         .gsub(%r{127\.0\.0\.1:\d+}, "127.0.0.1:__PORT__")
                         .gsub(%r{(transfers/)[A-Za-z0-9+_=-]+}, '\1__TOKEN__')
        "/qr_code/" + Base64.strict_encode64(decoded)
      end
      # Session transfer tokens embed a per-render expiry timestamp.
      out.gsub!(%r{(transfers/)[A-Za-z0-9+_=-]+}) { Regexp.last_match(1) + "__TOKEN__" }
      # Turbo marks lazy frames complete/busy and cable sources connected
      # asynchronously — snapshot race noise.
      out.gsub!(%r{(<turbo-frame\b[^>]*?) complete=""}) { Regexp.last_match(1) }
      out.gsub!(%r{(<turbo-frame\b[^>]*?) busy="" aria-busy="true"}) { Regexp.last_match(1) }
      out.gsub!(%r{(<turbo-cable-stream-source\b[^>]*?) connected=""}) { Regexp.last_match(1) }
      # Fresh-avatar and account-logo cache busters use the wall clock.
      out.gsub!(%r{((?:\bavatar|logo)\?v=)\d+}) { Regexp.last_match(1) + "__V__" }
      # Any leftover in-page reference to the run's random port.
      out.gsub!(%r{127\.0\.0\.1:\d+}, "127.0.0.1:__PORT__")
      # Morph/stream rewrites leave whitespace-only lines and inconsistent
      # indentation behind; HTML comparison is whitespace-insensitive —
      # except inside <pre>, where whitespace is content.
      # Morph/stream rewrites leave whitespace-only lines and inconsistent
      # indentation behind; HTML comparison is whitespace-insensitive —
      # except inside <pre>, where whitespace is content.
      out = out.split(/(<pre\b.*?<\/pre>)/m).map do |segment|
        next segment if segment.start_with?("<pre")

        segment.gsub(/[ \t]+\n/, "\n").gsub(/^[ \t]+/, "").gsub(/\n{2,}/, "\n")
      end.join
      # Our own injection is not app markup.
      out.gsub!(%r{<style id="parity-quiet">.*?</style>}m, "")
      # Attribute order shifts when Turbo re-serializes reloaded elements;
      # compare tags attribute-order-insensitively (attribute values never
      # contain raw '>' in serialized HTML).
      out = out.gsub(/<([a-zA-Z][a-zA-Z0-9:-]*)((?:\s+[\w:.@-]+(?:="[^"]*"|='[^']*'|[^\s>]+)?)*)\s*\/?>/) do
        opening = Regexp.last_match(0)
        tag = Regexp.last_match(1)
        attrs = Regexp.last_match(2).to_s.scan(/\s+[\w:.@-]+(?:="[^"]*"|='[^']*'|[^\s>]+)?/)
        closing = opening.end_with?("/>") ? "/>" : ">"
        "<#{tag}#{attrs.sort.join}#{closing}"
      end
      out
    end
  end
end

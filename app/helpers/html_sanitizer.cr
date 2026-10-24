# Allowlist HTML scrubber — port of the Rails oracle sanitizer layers
# (rails-html-sanitizer SafeListSanitizer + ContentFilters from
# once-campfire/app/helpers/content_filters*). The oracle runs the
# message body through three layers (SanitizeTags -> SanitizeAttributes
# -> a final sanitize before auto_link); the port keeps a single pass
# with a combined allowlist and applies it in ChatLayout.text_presentation
# before auto_link — the same point where the oracle does its final
# sanitize.
#
# Allowed elements/attributes pass through BYTE-IDENTICAL (output parity
# with the oracle on clean editor content): the scrubber copies the
# original tag text when the whole tag is allowed. Forbidden elements
# are removed entirely with their content (PermitScrubber ->
# node.unlink); event handlers and javascript: URLs are stripped at the
# attribute level.
module HtmlSanitizer
  # rails-html-sanitizer DEFAULT_ALLOWED_TAGS + ContentFilters::
  # EDITOR_FORMATTING_TAGS (s u table …) + action-text-attachment,
  # figure, figcaption (ContentFilters::SanitizeTags::ALLOWED_TAGS).
  ALLOWED_TAGS = %w(
    a abbr acronym address b big blockquote br cite code dd del dfn div dl dt
    em h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre samp small span
    strong sub sup time tt ul var
    s u table thead tbody tfoot tr th td
    action-text-attachment figure figcaption
  )

  # rails-html-sanitizer DEFAULT_ALLOWED_ATTRIBUTES + ActionText::
  # Attachment::ATTRIBUTES + ContentFilters::EDITOR_FORMATTING_ATTRIBUTES
  # (data-language) + class (ContentFilters::SanitizeAttributes).
  # target is from the Rails default list: mention/og-embed anchors keep
  # target="_top"/"_blank" after the oracle's final sanitize.
  ALLOWED_ATTRIBUTES = %w(
    abbr alt cite class datetime height href lang name src title width xml:lang
    sgid content-type url filename filesize previewable presentation caption content
    data-language target
  )

  # URI attributes: the scheme must be http/https/mailto, or the URL
  # must be relative (cf. Loofah::HTML5::Scrub.allowed_uri?).
  URI_ATTRIBUTES = %w(href src url)

  TAG_NAME  = /[a-zA-Z][a-zA-Z0-9_-]*/
  ATTR_NAME = /[a-zA-Z_:][-a-zA-Z0-9_:.]*/

  # Single pass over the string: allowed tags -> verbatim/rebuild,
  # forbidden -> removed with their content, comments/doctype -> removed.
  # NOTE: all indexing here is BYTE-based (byte_index/byte_slice) —
  # String#index, String#[] and MatchData#begin/#end are char-based on
  # this Crystal; mixing them with byte offsets breaks multibyte
  # content, so regex match lengths/positions are computed via
  # match[0].bytesize, not match.end.
  def self.sanitize(html : String) : String
    outp = IO::Memory.new
    size = html.bytesize
    i = 0
    while (lt = html.byte_index('<', i))
      outp << html.byte_slice(i, lt - i)
      rest = html.byte_slice(lt, size - lt)
      end_pos = size
      case
      when rest.starts_with?("<!--")
        close = html.byte_index("-->", lt + 4)
        end_pos = close ? close + 3 : size
      when rest.starts_with?("<!") || rest.starts_with?("<?")
        close = html.byte_index('>', lt + 2)
        end_pos = close ? close + 1 : size
      when rest.starts_with?("</")
        end_pos = closing_tag_end(html, rest, lt, outp)
      else
        end_pos = opening_tag_end(html, rest, lt, outp)
      end
      i = end_pos
      i = lt + 1 if i <= lt # guard against looping on a stray '<'
    end
    outp << html.byte_slice(i, size - i) if i < size
    outp.to_s
  end

  # </name …>: an allowed closing tag is verbatim, otherwise dropped.
  private def self.closing_tag_end(html : String, rest : String, lt : Int32, outp : IO) : Int32
    match = rest.match(/\A<\/(#{TAG_NAME})\s*>?/)
    unless match
      outp << "<" # "</" without a name — text
      return lt + 1
    end
    len = match[0].bytesize # match.end is char-based — take the length in bytes
    outp << html.byte_slice(lt, len) if ALLOWED_TAGS.includes?(match[1].not_nil!.downcase)
    lt + len
  end

  # <name attr…>: a forbidden element is removed with its content up to
  # the matching </name>; an allowed one is verbatim when every
  # attribute passes, otherwise rebuilt from the passing attributes.
  private def self.opening_tag_end(html : String, rest : String, lt : Int32, outp : IO) : Int32
    match = rest.match(/\A<(#{TAG_NAME})([^>]*?)(\/?)>/)
    unless match
      outp << "<" # stray "<" — text
      return lt + 1
    end
    name = match[1].not_nil!.downcase
    self_closing = !match[3]?.to_s.empty?
    consumed = lt + match[0].bytesize # match anchored at \A of rest
    unless ALLOWED_TAGS.includes?(name)
      return self_closing ? consumed : skip_element(html, name, consumed)
    end

    attrs = parse_attributes(match[2].to_s)
    if attrs.all?(&.ok)
      outp << html.byte_slice(lt, consumed - lt)
    else
      outp << '<' << match[1].not_nil!
      attrs.each { |a| outp << ' ' << a.raw if a.ok }
      outp << '/' if self_closing
      outp << '>'
    end
    consumed
  end

  # Skip the content of a forbidden element up to its matching closing
  # tag, accounting for nested same-name tags (node.unlink carries away
  # the children).
  private def self.skip_element(html : String, name : String, from : Int32) : Int32
    depth = 1
    cursor = from
    while (nxt = next_same_name(html, name, cursor))
      if nxt[:closing]
        depth -= 1
        return nxt[:end] if depth == 0
      else
        depth += 1 unless nxt[:self_closing]
      end
      cursor = nxt[:end]
    end
    html.bytesize
  end

  # Next occurrence of an opening/closing tag of name after pos.
  private def self.next_same_name(html : String, name : String, pos : Int32)
    regex = /<(\/?)#{Regex.escape(name)}(?:\s[^>]*)?(\/?)>/i
    match = regex.match(html, pos)
    return nil unless match
    byte_begin = html.char_index_to_byte_index(match.begin.not_nil!).not_nil!
    {
      closing:      !match[1]?.to_s.empty?,
      self_closing: !match[2]?.to_s.empty?,
      end:          byte_begin + match[0].not_nil!.bytesize,
    }
  end

  record Attr, raw : String, ok : Bool

  # Tag attribute parsing: raw is the original attribute text (verbatim
  # on rebuild), ok means the name is in the allowlist and (for URI
  # attributes) the scheme check passed. A bare valueless attribute
  # (=nil) is ok by name alone.
  private def self.parse_attributes(src : String) : Array(Attr)
    attrs = [] of Attr
    cursor = 0
    size = src.bytesize
    while cursor < size
      while cursor < size && src.byte_at(cursor).chr.whitespace?
        cursor += 1
      end
      break if cursor >= size
      # The window may split a multibyte char inside an attribute value —
      # PCRE2 fails on invalid UTF-8; trim back to a valid boundary
      # (ATTR_NAME is ASCII, a cut tail cannot be part of the name).
      window = src.byte_slice(cursor, {size - cursor, 64}.min)
      until window.empty? || window.valid_encoding?
        window = window.byte_slice(0, window.bytesize - 1)
      end
      name_match = window.match(/\A#{ATTR_NAME}/)
      break unless name_match && name_match.end.not_nil! > 0
      name = name_match[0]
      attr_end = cursor + name.bytesize
      value : String? = nil
      probe = attr_end
      while probe < size && src.byte_at(probe).chr.whitespace?
        probe += 1
      end
      if probe < size && src.byte_at(probe).chr == '='
        probe += 1
        while probe < size && src.byte_at(probe).chr.whitespace?
          probe += 1
        end
        if probe < size && (q = src.byte_at(probe).chr) && (q == '"' || q == '\'')
          close = src.byte_index(q, probe + 1) || size
          value = src.byte_slice(probe + 1, close - probe - 1)
          attr_end = {close + 1, size}.min
        else
          vm = src.byte_slice(probe, size - probe).match(/\A[^\s>]*/)
          value = vm.try(&.[0]).to_s
          attr_end = {probe + value.bytesize, size}.min
        end
      end
      ok = ALLOWED_ATTRIBUTES.includes?(name.downcase) &&
           (!URI_ATTRIBUTES.includes?(name.downcase) || value.nil? || safe_uri?(value))
      attrs << Attr.new(src.byte_slice(cursor, attr_end - cursor), ok)
      cursor = attr_end
    end
    attrs
  end

  # Relative URLs without a scheme are safe; an explicit scheme must be
  # http/https/mailto. The check runs on the entity-decoded value (the
  # browser decodes the attribute before parsing the URL); control
  # characters and spaces before the scheme do not count as separators.
  ENTITY = /&#(x[0-9a-fA-F]+|[0-9]+);/

  private def self.safe_uri?(value : String) : Bool
    decoded = decode_entities(value)
    scheme = decoded.match(/\A[\s\x00-\x1f]*([a-zA-Z][a-zA-Z0-9+.\-]*):/)
    scheme.nil? || {"http", "https", "mailto"}.includes?(scheme[1].not_nil!.downcase)
  end

  private def self.decode_entities(value : String) : String
    outp = String::Builder.new
    pos = 0
    while (match = ENTITY.match(value, pos))
      match_begin = value.char_index_to_byte_index(match.begin.not_nil!).not_nil!
      match_end = match_begin + match[0].not_nil!.bytesize
      outp << value.byte_slice(pos, match_begin - pos)
      token = match[1].not_nil!
      codepoint = token.starts_with?('x') ? token[1..].to_i?(16) : token.to_i?
      if codepoint && codepoint > 0 && codepoint < 0xD800
        outp << codepoint.chr
      else
        outp << match[0]
      end
      pos = match_end
    end
    outp << value.byte_slice(pos, value.bytesize - pos) if pos < value.bytesize
    outp.to_s
  end
end

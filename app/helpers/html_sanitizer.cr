# Allowlist-скраббер HTML — порт санитайзер-слоёв Rails-оракула
# (rails-html-sanitizer 1.7.1 SafeListSanitizer + ContentFilters
# once-campfire/app/helpers/content_filters*). Оракул прогоняет тело
# сообщения через три слоя (SanitizeTags → SanitizeAttributes →
# финальный sanitize перед auto_link); порт держит один проход с
# объединённым allowlist и применяет его в ChatLayout.text_presentation
# перед auto_link — той же точке, где оракул делает финальный sanitize.
#
# Разрешённые элементы/атрибуты проходят ПОБАЙТОВО НЕИЗМЕННЫМИ
# (паритет вывода с оракулом на чистом контенте редактора):
# скраббер копирует исходный текст тега, если весь тег разрешён.
# Запрещённые элементы удаляются целиком вместе с содержимым
# (PermitScrubber → node.unlink), event-handler'ы и javascript:-ссылки
# срезаются на атрибутном уровне.
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
  ALLOWED_ATTRIBUTES = %w(
    abbr alt cite class datetime height href lang name src title width xml:lang
    sgid content-type url filename filesize previewable presentation caption content
    data-language
  )

  # Атрибуты-ссылки: схема допускается только http/https/mailto либо
  # относительный URL (аналог Loofah::HTML5::Scrub.allowed_uri?).
  URI_ATTRIBUTES = %w(href src url)

  TAG_NAME  = /[a-zA-Z][a-zA-Z0-9_-]*/
  ATTR_NAME = /[a-zA-Z_:][-a-zA-Z0-9_:.]*/

  # Один проход по строке: теги разрешены → verbatim/пересборка,
  # запрещены → удаление с содержимым, комментарии/doctype → удаление.
  def self.sanitize(html : String) : String
    outp = IO::Memory.new
    size = html.bytesize
    i = 0
    while (lt = html.index('<', i))
      outp << html[i...lt]
      rest = html.byte_slice(lt, size - lt)
      end_pos = size
      case
      when rest.starts_with?("<!--")
        close = html.index("-->", lt + 4)
        end_pos = close ? close + 3 : size
      when rest.starts_with?("<!") || rest.starts_with?("<?")
        close = html.index('>', lt + 2)
        end_pos = close ? close + 1 : size
      when rest.starts_with?("</")
        end_pos = closing_tag_end(html, rest, lt, outp)
      else
        end_pos = opening_tag_end(html, rest, lt, outp)
      end
      i = end_pos
      i = lt + 1 if i <= lt # защита от зацикливания на мусорном «<»
    end
    outp << html[i..] if i < size
    outp.to_s
  end

  # </name …>: разрешённый закрывающий тег — verbatim, иначе срезается.
  private def self.closing_tag_end(html : String, rest : String, lt : Int32, outp : IO) : Int32
    match = rest.match(/\A<\/(#{TAG_NAME})\s*>?/)
    unless match
      outp << "<" # «</» без имени — текст
      return lt + 1
    end
    outp << html[lt...(lt + match.end.not_nil!)] if ALLOWED_TAGS.includes?(match[1].not_nil!.downcase)
    lt + match.end.not_nil!
  end

  # <name attr…>: запрещённый элемент удаляется вместе с содержимым до
  # парного </name>; разрешённый — verbatim, если все атрибуты прошли,
  # иначе пересборка из прошедших атрибутов.
  private def self.opening_tag_end(html : String, rest : String, lt : Int32, outp : IO) : Int32
    match = rest.match(/\A<(#{TAG_NAME})([^>]*?)(\/?)>/)
    unless match
      outp << "<" # одиночный «<» — текст
      return lt + 1
    end
    name = match[1].not_nil!.downcase
    self_closing = !match[3]?.to_s.empty?
    consumed = lt + match.end.not_nil!
    unless ALLOWED_TAGS.includes?(name)
      return self_closing ? consumed : skip_element(html, name, consumed)
    end

    attrs = parse_attributes(match[2].to_s)
    if attrs.all?(&.ok)
      outp << html[lt...consumed]
    else
      outp << '<' << match[1].not_nil!
      attrs.each { |a| outp << ' ' << a.raw if a.ok }
      outp << '/' if self_closing
      outp << '>'
    end
    consumed
  end

  # Пропуск содержимого запрещённого элемента до парного закрывающего
  # тега с учётом вложенных одноимённых (node.unlink уносит детей).
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

  # Следующее вхождение открывающего/закрывающего тега name после pos.
  private def self.next_same_name(html : String, name : String, pos : Int32)
    regex = /<(\/?)#{Regex.escape(name)}(?:\s[^>]*)?(\/?)>/i
    match = regex.match(html, pos)
    return nil unless match
    {
      closing:      !match[1]?.to_s.empty?,
      self_closing: !match[2]?.to_s.empty?,
      end:          match.end.not_nil!,
    }
  end

  record Attr, raw : String, ok : Bool

  # Разбор атрибутов тега: raw — исходный текст атрибута (verbatim при
  # пересборке), ok — имя в allowlist и (для URI-атрибутов) схема
  # прошла проверку. Голый атрибут без значения (=nil) ok по имени.
  private def self.parse_attributes(src : String) : Array(Attr)
    attrs = [] of Attr
    cursor = 0
    size = src.bytesize
    while cursor < size
      while cursor < size && src.byte_at(cursor).chr.whitespace?
        cursor += 1
      end
      break if cursor >= size
      name_match = src.byte_slice(cursor, {size - cursor, 64}.min).match(/\A#{ATTR_NAME}/)
      break unless name_match && name_match.end.not_nil! > 0
      name = name_match[0]
      attr_end = cursor + name_match.end.not_nil!
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
          close = src.index(q, probe + 1) || size
          value = src[(probe + 1)...close]
          attr_end = {close + 1, size}.min
        else
          vm = src.byte_slice(probe, size - probe).match(/\A[^\s>]*/)
          value = vm.try(&.[0]).to_s
          attr_end = {probe + vm.try(&.end).not_nil!, size}.min
        end
      end
      ok = ALLOWED_ATTRIBUTES.includes?(name.downcase) &&
           (!URI_ATTRIBUTES.includes?(name.downcase) || value.nil? || safe_uri?(value))
      attrs << Attr.new(src[cursor...attr_end], ok)
      cursor = attr_end
    end
    attrs
  end

  # Относительные URL без схемы — безопасны; явная схема — только
  # http/https/mailto. Проверка по entity-декодированному значению
  # (браузер декодирует атрибут до разбора URL), управляющие символы и
  # пробелы перед схемой не считаются разделителем.
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
      match_begin = match.begin.not_nil!
      match_end = match.end.not_nil!
      outp << value[pos...match_begin]
      token = match[1].not_nil!
      codepoint = token.starts_with?('x') ? token[1..].to_i?(16) : token.to_i?
      if codepoint && codepoint > 0 && codepoint < 0xD800
        outp << codepoint.chr
      else
        outp << match[0]
      end
      pos = match_end
    end
    outp << value[pos..] if pos < value.bytesize
    outp.to_s
  end
end

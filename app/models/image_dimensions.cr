# Размеры изображения из заголовка файла — PNG/JPEG/GIF/WebP без
# внешних зависимостей. Порт того, что делает
# ActiveStorage::Analyzer::ImageAnalyzer референса: Rails после
# загрузки дописывает width/height в metadata блоба, и оттуда их берёт
# Messages::AttachmentPresentation#preview_dimensions. Здесь размеры
# читаются тем же INSERT'ом в MessageCreator.store_attachment.
module ImageDimensions
  # {width, height} из первых байтов файла; nil — формат не распознан
  # или заголовок короче ожидаемого (Rails в этом случае оставляет
  # metadata пустым).
  def self.of(bytes : Bytes) : {Int32, Int32}?
    png(bytes) || gif(bytes) || webp(bytes) || jpeg(bytes)
  end

  # PNG: сигнатура 8 байт, первый чанк IHDR — width@16, height@20
  # (big-endian).
  private def self.png(b : Bytes)
    return nil unless b.size >= 24
    return nil unless b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E &&
                      b[3] == 0x47 && b[4] == 0x0D && b[5] == 0x0A &&
                      b[6] == 0x1A && b[7] == 0x0A
    return nil unless b[12] == 0x49 && b[13] == 0x48 && b[14] == 0x44 && b[15] == 0x52
    {be32(b, 16), be32(b, 20)}
  end

  # GIF87a/GIF89a: logical screen size @6 (little-endian).
  private def self.gif(b : Bytes)
    return nil unless b.size >= 10
    return nil unless b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 &&
                      (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61
    {le16(b, 6), le16(b, 8)}
  end

  # WebP: RIFF....WEBP, размеры в первом чанке VP8X / VP8 / VP8L.
  private def self.webp(b : Bytes)
    return nil unless b.size >= 30
    return nil unless b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
                      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
    if b[12] == 0x56 && b[13] == 0x50 && b[14] == 0x38 && b[15] == 0x58
      # VP8X: canvas width-1/height-1 — по 3 байта LE @24/@27
      w = b[24].to_i32 | (b[25].to_i32 << 8) | (b[26].to_i32 << 16)
      h = b[27].to_i32 | (b[28].to_i32 << 8) | (b[29].to_i32 << 16)
      {w &+ 1, h &+ 1}
    elsif b[12] == 0x56 && b[13] == 0x50 && b[14] == 0x38 && b[15] == 0x20
      # VP8 (lossy): keyframe — sync 9D 01 2A @23, размер 14 бит LE @26
      return nil unless b[23] == 0x9D && b[24] == 0x01 && b[25] == 0x2A
      {le16(b, 26) & 0x3FFF, le16(b, 28) & 0x3FFF}
    elsif b[12] == 0x56 && b[13] == 0x50 && b[14] == 0x38 && b[15] == 0x4C
      # VP8L (lossless): signature 0x2F @20, затем 32 бита LE: width
      # биты 0-13, height биты 14-27
      bits = b[21].to_i32 | (b[22].to_i32 << 8) | (b[23].to_i32 << 16) | (b[24].to_i32 << 24)
      {bits & 0x3FFF, (bits >> 14) & 0x3FFF}
    else
      nil
    end
  end

  # JPEG: скан маркеров до SOF0..SOF15 (кроме C4/C8/CC — не SOF);
  # внутри SOF height@5, width@7 от начала сегмента (big-endian).
  private def self.jpeg(b : Bytes)
    return nil unless b.size >= 4 && b[0] == 0xFF && b[1] == 0xD8
    i = 2
    while i + 9 < b.size
      return nil unless b[i] == 0xFF
      marker = b[i + 1]
      if marker == 0xD8 || marker == 0x01 || (0xD0 <= marker <= 0xD7)
        return nil # standalone-маркер без длины — битый поток
      end
      break if marker == 0xDA # SOS — дальше данные, SOF не нашли
      len = (b[i + 2].to_i32 << 8) | b[i + 3].to_i32
      if 0xC0 <= marker <= 0xCF && !{0xC4, 0xC8, 0xCC}.includes?(marker)
        h = (b[i + 5].to_i32 << 8) | b[i + 6].to_i32
        w = (b[i + 7].to_i32 << 8) | b[i + 8].to_i32
        return {w, h} if w > 0 && h > 0
      end
      i &+= 2 &+ len
    end
    nil
  end

  private def self.be32(b : Bytes, i : Int32) : Int32
    (b[i].to_i32 << 24) | (b[i + 1].to_i32 << 16) | (b[i + 2].to_i32 << 8) | b[i + 3].to_i32
  end

  private def self.le16(b : Bytes, i : Int32) : Int32
    b[i].to_i32 | (b[i + 1].to_i32 << 8)
  end
end

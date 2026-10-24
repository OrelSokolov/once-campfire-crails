# Initials SVG avatars (users/avatars/show.svg.erb of the reference), included
# in Users::AvatarsController; caching/serving lives in the controller.
require "digest/crc32"

module Users::AvatarsHelper
  # 18-color palette picked by CRC32 of the id, byte-identical to Ruby's Zlib.crc32.
  AVATAR_COLORS = {"#AF2E1B", "#CC6324", "#3B4B59", "#BFA07A", "#ED8008",
                   "#ED3F1C", "#BF1B1B", "#736B1E", "#D07B53", "#736356",
                   "#AD1D1D", "#BF7C2A", "#C09C6F", "#698F9C", "#7C956B",
                   "#5D618F", "#3B3633", "#67695E"}

  # 512px rx=50 square with User#initials (scan(/\b\w/).join); with 3+ initials
  # textLength="85%". Output bytes match the reference ERB render exactly.
  def initials_svg(user : User?) : String
    name = user.try(&.name).to_s
    initials = name.scan(/\b\w/).join
    color = if (uid = user.try(&.id))
              AVATAR_COLORS[(Digest::CRC32.checksum(uid.to_s) % AVATAR_COLORS.size).to_i]
            else
              AVATAR_COLORS[0]
            end
    text_length = initials.size >= 3 ? %(textLength="85%" lengthAdjust="spacingAndGlyphs") : ""
    String.build do |io|
      io << %(<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"\n)
      io << %(  viewBox="0 0 512 512" class="avatar" aria-hidden="true">\n)
      io << %(  <defs>\n    <clipPath id="porthole">\n)
      io << %(      <circle cx="50%" cy="50%" r="50%" />\n)
      io << %(    </clipPath>\n  </defs>\n\n  <g>\n)
      io << %(    <rect width="100%" height="100%" rx="50" fill=") << color << %(" />\n\n)
      io << %(    <text x="50%" y="50%" fill="#FFFFFF"\n)
      io << %(      text-anchor="middle" dy="0.35em"\n)
      io << %(      ) << text_length << %(\n)
      io << %(      font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"\n)
      io << %(      font-size="230"\n      font-weight="800"\n      letter-spacing="-5">\n)
      io << %(      ) << HTML.escape(initials) << %(\n    </text>\n  </g>\n</svg>\n)
    end
  end
end

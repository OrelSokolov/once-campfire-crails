# Мини-порт useragent 0.16 (ApplicationPlatform референса): только
# классификация, необходимая pwa-диалогам (browser/system/install
# instructions). Токены продуктов UA сверяются со списком известных
# браузеров; headless Chrome («HeadlessChrome/…») в списке отсутствует и
# потому классифицируется по следующему токену «Safari» — ровно как в
# ruby-геме, что даёт Safari+Linux в parity-прогоне.
class PlatformAgent
  BROWSERS = %w[Firefox FxiOS Chrome Opera MSIE Edg Edge Safari]

  def initialize(@ua : String)
  end

  def match?(pattern : Regex) : Bool
    !(@ua =~ pattern).nil?
  end

  private def products : Array(String)
    @ua.split(' ').map { |token| token.split('/')[0] }
  end

  def browser : String
    products.find { |p| BROWSERS.includes?(p) }.to_s
  end

  def firefox? : Bool
    browser =~ /Firefox|Fxios/ ? true : false
  end

  def chrome? : Bool
    browser =~ /Chrome/ ? true : false
  end

  def safari? : Bool
    browser =~ /Safari/ ? true : false
  end

  def edge? : Bool
    browser =~ /Edg/ ? true : false
  end

  def ios? : Bool
    match?(/iPhone|iPad/)
  end

  def android? : Bool
    match?(/Android/)
  end

  def mac? : Bool
    match?(/Macintosh/)
  end

  def mobile? : Bool
    ios? || android?
  end

  def desktop? : Bool
    !mobile?
  end

  def windows? : Bool
    operating_system == "Windows"
  end

  def operating_system : String
    case @ua
    when /Android/   then "Android"
    when /iPad/      then "iPad"
    when /iPhone/    then "iPhone"
    when /Macintosh/ then "macOS"
    when /Windows/   then "Windows"
    when /CrOS/      then "ChromeOS"
    else @ua =~ /Linux|X11/ ? "Linux" : ""
    end
  end
end

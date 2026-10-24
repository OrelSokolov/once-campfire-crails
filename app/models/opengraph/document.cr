class Opengraph::Document
  ATTRIBUTE_NAMES = %w(title url image description)

  def initialize(html : String?)
    @html = html
  end

  def opengraph_attributes : Hash(String, String)
    attributes = {} of String => String
    document = XML.parse_html((@html.to_s).scrub) rescue return attributes
    document.xpath_nodes("//meta").each do |tag|
      key = tag["property"]? || tag["name"]?
      content = tag["content"]?
      next unless key && content && !content.empty?
      next unless key.starts_with?("og:")
      name = key[3..]
      attributes[name] = content if ATTRIBUTE_NAMES.includes?(name)
    end
    attributes
  end
end

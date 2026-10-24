module AllowBrowser
  VERSION_MINIMUMS = {
    "chrome"  => 120.0,
    "firefox" => 121.0,
    "opera"   => 104.0,
  }
  SAFARI_MINIMUM = 17.2

  private def verify_supported_browser : Nil
    ua = request.headers["User-Agent"]?
    return unless ua
    return unless (browser = blocked_browser(ua))
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: ChatERB.new(ua: ua).incompatible_browser.to_s)
  end

  private def blocked_browser(ua : String) : String?
    VERSION_MINIMUMS.each do |browser, minimum|
      if (match = ua.match(/#{browser}[\/ ]([\d.]+)/i))
        version = match[1].to_f?
        return browser if version && version < minimum
      end
    end
    if (match = ua.match(/Version\/([\d.]+).*Safari/i)) &&
       !ua.matches?(/Chrome|Chromium|Edg|OPR/i)
      version = match[1].to_f?
      return "safari" if version && version < SAFARI_MINIMUM
    end
    nil
  end
end

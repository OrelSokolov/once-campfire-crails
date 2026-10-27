# Port of concerns/allow_browser.rb: VERSIONS + allow_browser versions:.
# Deviation от оракула: `block: -> { render template: ... }` — лямбду
# Crystal не может instance_exec (см. RateLimiting в action_pack_cr),
# поэтому обработчик передаётся блоком макроса allow_browser ... do ...
# end; UA-детекция целиком в action_pack_cr (порт гема useragent).
module AllowBrowser
  VERSIONS = {safari: 17.2, chrome: 120, firefox: 121, opera: 104, ie: false}

  macro included
    allow_browser versions: VERSIONS do
      # Oracle sessions/incompatible_browser: @page_title picks the apple
      # messages flavor; the template renders in the ChatERB context, so
      # the title lives here. The shell comes from layouts/application.
      platform = ApplicationPlatform.new(request.headers["User-Agent"].to_s)
      @page_title = platform.apple_messages? ? "Campfire" : "Unsupported browser"
      render(html: __render_layout {
        ChatERB.new(ua: request.headers["User-Agent"].to_s).incompatible_browser.to_s
      }.to_s)
    end
  end
end

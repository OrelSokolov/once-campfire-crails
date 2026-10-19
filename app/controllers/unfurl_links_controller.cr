# POST /unfurl_link — unfurl вставленной ссылки (референс:
# unfurl_links_controller.rb). Один дедлайн 10 секунд на всё, куда
# ведёт ссылка: DNS, редиректы, страницу и проверку картинки; нет
# валидных og-данных → 204. Клиент — app/javascript/controllers/
# unfurl_controller.js (JSON: title, url, image, description).
class UnfurlLinksController < ApplicationController
  DEADLINE = 10.0 # секунд (Time::Instant)

  def create
    url = params["url"]?.to_s
    # params.require(:url) → ActionController::ParameterMissing → 400
    if url.empty?
      return render(plain: "", status: :bad_request)
    end

    if opengraph = unfurl(url)
      render(json: opengraph.to_json)
    else
      render(plain: "", status: :no_content)
    end
  end

  # Timeout.timeout(DEADLINE) референса: дедлайн передаётся вниз
  # (остаток бюджета — на каждый connect/read/write), ошибку сети
  # ловим как таймаут — nil → 204.
  private def unfurl(url : String) : Opengraph::Metadata?
    deadline = Time.instant + DEADLINE.seconds
    opengraph = Opengraph::Metadata.from_url(url, deadline)
    opengraph if opengraph.valid?
  rescue ex
    nil
  end
end

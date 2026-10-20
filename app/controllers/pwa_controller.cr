# GET /webmanifest(.json) — порт PwaController#manifest (pwa/
# manifest.json.erb): web app manifest с иконками аккаунта
# (fresh_account_logo) и скриншотами; линкуется из <head> (tag.link
# rel: "manifest"). allow_unauthenticated_access — манифест публичен.
# GET /service-worker — JS воркер пуш-нотификаций (pwa/service_worker.js
# референса): showNotification + setAppBadge на push-событие,
# notificationclick — переход по data.path. URL стабильный, в корне —
# потому не ассетный путь (skip_forgery_protection референса; у порта
# защита header_only, GET не требует токенов).
class PwaController < ApplicationController
  skip_before_action :require_authentication

  def manifest
    @account = Account.take
    response.headers["Cache-Control"] = "public, max-age=300"
    render(template: "pwa/manifest.json.jbuilder")
  end

  # Стабильный URL в корне (pwa_controller.rb: "We need a stable URL at
  # the root, so we can't use the regular asset path here").
  SERVICE_WORKER_JS = <<-JS
    self.addEventListener("push", async (event) => {
      const data = await event.data.json()
      event.waitUntil(Promise.all([ showNotification(data), updateBadgeCount(data.options) ]))
    })

    async function showNotification({ title, options }) {
      return self.registration.showNotification(title, options)
    }

    async function updateBadgeCount({ data: { badge } }) {
      return self.navigator.setAppBadge?.(badge || 0)
    }

    self.addEventListener("notificationclick", (event) => {
      event.notification.close()

      const url = new URL(event.notification.data.path, self.location.origin).href
      event.waitUntil(openURL(url))
    })

    async function openURL(url) {
      const clients = await self.clients.matchAll({ type: "window" })
      const focused = clients.find((client) => client.focused)

      if (focused) {
        await focused.navigate(url)
      } else {
        await self.clients.openWindow(url)
      }
    }
  JS

  def service_worker
    response.headers["Content-Type"] = "application/javascript"
    response.headers["Cache-Control"] = "public, max-age=300"
    render(plain: SERVICE_WORKER_JS)
  end
end

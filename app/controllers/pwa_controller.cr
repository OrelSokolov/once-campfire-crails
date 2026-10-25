# GET /webmanifest(.json) — the web app manifest with the account's icons and
# screenshots, linked from <head> (tag.link rel: "manifest"); public.
# GET /service-worker — the push notifications service worker: showNotification +
# setAppBadge on push, notificationclick navigates to data.path. The URL is stable and
# at the root, so not an asset path.
class PwaController < ApplicationController
  allow_unauthenticated_access

  def manifest
    @account = Account.take
    response.headers["Cache-Control"] = "public, max-age=300"
    render(template: "pwa/manifest.json.jbuilder")
  end

  # Stable URL at the root (pwa_controller.rb: "We need a stable URL at the root, so
  # we can't use the regular asset path here").
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

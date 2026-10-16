# GET /webmanifest(.json) — порт PwaController#manifest (pwa/
# manifest.json.erb): web app manifest с иконками аккаунта
# (fresh_account_logo) и скриншотами; линкуется из <head> (tag.link
# rel: "manifest"). allow_unauthenticated_access — манифест публичен.
# (service-worker/пуш-нотификации референса не портированы.)
# Разметка JSON — во вьюхе app/views/pwa/manifest.json.jbuilder.
class PwaController < ApplicationController
  skip_before_action :require_authentication

  def manifest
    @account = Account.take
    response.headers["Cache-Control"] = "public, max-age=300"
    render(template: "pwa/manifest.json.jbuilder")
  end
end

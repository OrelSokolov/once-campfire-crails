# GET /webmanifest(.json) — порт PwaController#manifest (pwa/
# manifest.json.erb): web app manifest с иконками аккаунта
# (fresh_account_logo) и скриншотами; линкуется из <head> (tag.link
# rel: "manifest"). allow_unauthenticated_access — манифест публичен.
# (service-worker/пуш-нотификации референса не портированы.)
class PwaController < ApplicationController
  skip_before_action :require_authentication

  def manifest
    account = Account.take
    response.headers["Cache-Control"] = "public, max-age=300"
    render(json: JSON.build do |json|
      json.object do
        json.field "name", account.try(&.name).to_s.presence || "Campfire"
        json.field "icons" do
          json.array do
            json.object do
              json.field "src", ChatLayout.fresh_account_logo_path(account, "small")
              json.field "type", "image/png"
              json.field "sizes", "192x192"
            end
            json.object do
              json.field "src", ChatLayout.fresh_account_logo_path(account)
              json.field "type", "image/png"
              json.field "sizes", "512x512"
            end
            json.object do
              json.field "src", ChatLayout.fresh_account_logo_path(account)
              json.field "type", "image/png"
              json.field "sizes", "512x512"
              json.field "purpose", "maskable"
            end
          end
        end
        json.field "start_url", "/"
        json.field "display", "standalone"
        json.field "scope", "/"
        json.field "description", "A chat app from the makers of Basecamp and HEY."
        json.field "categories" do
          json.array do
            %w[social business productivity].each { |c| json.string c }
          end
        end
        json.field "theme_color", "#ffffff"
        json.field "background_color", "#ffffff"
        json.field "shortcuts" do
          json.array do
            json.object do
              json.field "name", "New chat room"
              json.field "description", "Open Campfire and start a new chat room"
              json.field "url", "rooms/opens/new"
              json.field "icons" do
                json.array do
                  json.object do
                    json.field "src", ChatLayout.asset("add.svg")
                    json.field "sizes", "any"
                  end
                end
              end
            end
            json.object do
              json.field "name", "My profile"
              json.field "description", "Open Campfire and view your profile"
              json.field "url", "/users/me/profile"
              json.field "icons" do
                json.array do
                  json.object do
                    json.field "src", ChatLayout.asset("person.svg")
                    json.field "sizes", "any"
                  end
                end
              end
            end
          end
        end
        json.field "screenshots" do
          json.array do
            screenshot(json, "screenshots/android-chat.png",
              "Campfire is an installable, self-hosted group chat system.")
            screenshot(json, "screenshots/android-sidebar.png",
              "Easily invite people. Make rooms. @mentions, DMs, and mobile support.")
            screenshot(json, "screenshots/android-dark-mode.png",
              "Full support for dark mode, customizable to your brand.")
          end
        end
      end
    end)
  end

  private def screenshot(json : JSON::Builder, name : String, label : String) : Nil
    json.object do
      json.field "src", ChatLayout.asset(name)
      json.field "sizes", "1080x2400"
      json.field "form_factor", "narrow"
      json.field "label", label
    end
  end
end

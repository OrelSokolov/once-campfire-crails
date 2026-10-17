# /account/custom_styles(/edit) — кастомный CSS аккаунта (референс:
# routes.js + custom_styles.eta): textarea account[custom_styles],
# PATCH → UPDATE accounts.custom_styles; layout инжектит <style>
# (см. ChatLayout.head). Только администратор.
# Разметка GET — app/views/custom_styles/edit.html.erb (implicit render).
class CustomStylesController < ApplicationController
  before_action :require_admin

  # edit.html.erb: аккаунт (текущий CSS в textarea) и viewer.
  @account : Account?
  @user : User?

  def edit
    @account = Account.take.not_nil!
    @user = current_user.not_nil!
  end

  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    account = Account.take.not_nil!
    nested = params["account"]?
    if nested.is_a?(ActionController::Parameters) && (styles = nested["custom_styles"]?)
      account.custom_styles = styles.to_s
    end
    account.updated_at = Time.utc
    account.save!
    redirect_to "/account/custom_styles/edit"
  end

  private def require_admin : Nil
    unless current_user.not_nil!.role == 1
      render(plain: "forbidden", status: 403)
    end
  end

  # ————— ERB-хелперы (app/views/custom_styles/edit.html.erb) —————

  # head + body + nav (только «назад» на /account/edit) + main.
  private def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("custom-styles", "Custom CSS", user,
      nav_html: ChatLayout.nav_back("/account/edit")))
  end

  private def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close)
  end

  private def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end
end

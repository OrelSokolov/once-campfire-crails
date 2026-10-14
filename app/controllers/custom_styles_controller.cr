# /account/custom_styles(/edit) — кастомный CSS аккаунта (референс:
# routes.js + custom_styles.eta): textarea account[custom_styles],
# PATCH → UPDATE accounts.custom_styles; layout инжектит <style>
# (см. ChatLayout.head). Только администратор.
class CustomStylesController < ApplicationController
  before_action :require_admin

  def edit
    account = Account.take.not_nil!
    user = current_user.not_nil!
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.head("Custom CSS", user, nil, chat: false)
      io << %(<body>\n<main id="main-content">\n)
      io << %(<section class="panel panel--wide txt-align-center flex flex-column">)
      io << %(<form action="/account/custom_styles" accept-charset="UTF-8" )
      io << %(method="post" class="flex flex-column gap">)
      io << %(<input type="hidden" name="_method" value="patch">)
      io << %(<h1 class="margin-none">Custom CSS</h1>\n)
      io << %(<label class="flex align-start gap flex-item-grow">)
      io << %(<textarea name="account[custom_styles]" id="account_custom_styles" )
      io << %(class="input txt--small" placeholder="Add CSS styles…" autocomplete="off" )
      io << %(spellcheck="false" rows="16">)
      io << HTML.escape(account.custom_styles.to_s) << %(</textarea></label>\n)
      io << %(<button class="btn btn--reversed center txt-large" type="submit">)
      io << %(<span class="for-screen-reader">Save changes</span></button>\n)
      io << %(</form></section>\n</main>\n</body>\n</html>\n)
    end)
  end

  def update
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
end

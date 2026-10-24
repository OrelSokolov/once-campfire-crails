class Accounts::Bots::KeysController < ApplicationController
  before_action :ensure_can_administer

  def update
    # find-bang: RecordNotFound -> 404 via the middleware rescue ladder
    bot = User.active_bots.find(params["bot_id"].to_s)
    Campfire::ResponseCache.invalidate!
    bot.bot_token = User.generate_bot_token
    bot.updated_at = Time.utc
    bot.save!
    redirect_to account_bots_url
  end
end

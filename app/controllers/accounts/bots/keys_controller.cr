# PUT /account/bots/:bot_id/key — ротация ключа бота (порт
# Accounts::Bots::KeysController: User.active_bots.find(...).
# reset_bot_key), кнопка btn--regenerate в accounts/bots/edit.
# Только администраторы (ensure_can_administer).
class Accounts::Bots::KeysController < ApplicationController
  before_action :require_admin

  # User::Bot#reset_bot_key: bot_token = generate_bot_token — та же
  # генерация, что при создании бота в bots_controller (hex(6)).
  def update
    bot = User.where("id = ? AND role = 2 AND status = 0",
      params["bot_id"].to_s.to_i64).take
    return head(:not_found) unless bot
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    bot.bot_token = Random::Secure.hex(6)
    bot.updated_at = Time.utc
    bot.save!
    redirect_to account_bots_url
  end
end

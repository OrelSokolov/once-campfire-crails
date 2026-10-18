# GET/PATCH /account(/edit) — настройки аккаунта (референс:
# accounts_controller.rb + accounts/edit.html.erb): имя, настройка
# создания комнат, invite-ссылка. update — только администратор
# (role=1), edit — всем авторизованным (ветка admin/non-admin).
# Файл идёт первым по алфавиту в app/controllers/** — ApplicationController
# нужно потребовать явно.
require "./application_controller"

class AccountsController < ApplicationController
  include AccountsHelpers

  before_action :require_admin, only: [:update]

  # edit.html.erb: аккаунт, viewer (ветка admin/non-admin), состояние
  # restrict-свитча, invite-ссылка + QR-путь, юзеры аккаунта.
  # Юзеры — как Rails AccountsController#edit: visible_to (админ видит
  # active+banned, остальные — active), ordered LOWER(name), администраторы
  # первым блоком, затем member-роль (боты excluded).
  @account : Account?
  @user : User?
  @restrict : Bool = false
  @join_url : String = ""
  @qr_path : String = ""
  @admins : Array(User) = [] of User
  @members : Array(User) = [] of User

  # HTML-партиал nav аккаунта (account_nav.eta): назад + боты/кастомные
  # стили для админа; рендерится обёрткой AccountsHelpers#account_nav.
  compile_partials({
    "accounts/nav" => {path: "app/views/accounts/_nav.html.erb",
                       locals: {"user" => User}},
  })

  def edit
    account = set_account
    user = current_user.not_nil!
    @user = user
    @restrict = account.restrict_room_creation_to_administrators?
    @join_url = origin + "/join/" + account.join_code.to_s
    @qr_path = "/qr_code/" + Base64.urlsafe_encode(@join_url, padding: false)
    status_scope = user.role == 1 ? "status IN (0, 2)" : "status = 0"
    # Rails scope :ordered → ORDER BY LOWER(name): функцию в order() шарды
    # не поддерживают (order_term квотит её как колонку) — сортируем в памяти.
    @admins = User.where("#{status_scope} AND role = 1").to_a
      .sort_by(&.name.to_s.downcase)
    @members = User.where("#{status_scope} AND role = 0").to_a
      .sort_by(&.name.to_s.downcase)
  end

  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    account = set_account
    if name = account_params["name"]?
      account.name = name.to_s
    end
    # restrict_room_creation_to_administrators (settings JSON, PUT-свитч)
    if (settings = account_params["settings"]?).is_a?(ActionController::Parameters) &&
       (value = settings["restrict_room_creation_to_administrators"]?)
      account.restrict_room_creation_to_administrators = value.to_s == "true"
    end
    account.save!
    redirect_to "/account/edit"
  end

  private def set_account : Account
    @account = Account.take
    @account.not_nil!
  end

  # Strong Parameters (Rails account_params): имя + restrict-свитч.
  private def account_params : ActionController::Parameters
    params.require("account")
      .permit("name", {"settings" => ["restrict_room_creation_to_administrators"]})
  end
end

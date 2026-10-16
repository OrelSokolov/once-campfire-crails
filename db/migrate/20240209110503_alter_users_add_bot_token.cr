# Ported 1:1 from ~/once-campfire (Rails).
class AlterUsersAddBotToken < ActiveRecord::Migration
  def change
    add_column :users, :bot_token, :string
    add_index :users, :bot_token, unique: true

    # Bot users do not use passwords
    change_column_null :users, :password_digest, true
  end
end

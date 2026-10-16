# Ported 1:1 from ~/once-campfire (Rails).
class AddAccountSettings < ActiveRecord::Migration
  def change
    add_column :accounts, :settings, :json
  end
end

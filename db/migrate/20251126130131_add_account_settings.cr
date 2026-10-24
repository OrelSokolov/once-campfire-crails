class AddAccountSettings < ActiveRecord::Migration
  def change
    add_column :accounts, :settings, :json
  end
end

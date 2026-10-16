# Ported 1:1 from ~/once-campfire (Rails).
class AddCustomStylesToAccounts < ActiveRecord::Migration
  def change
    add_column :accounts, :custom_styles, :text
  end
end

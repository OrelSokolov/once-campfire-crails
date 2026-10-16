# Ported 1:1 from ~/once-campfire (Rails).
class AddSingletonConstraintToAccounts < ActiveRecord::Migration
  def change
    add_column :accounts, :singleton_guard, :integer, default: 0, null: false
    add_index :accounts, :singleton_guard, unique: true
  end
end

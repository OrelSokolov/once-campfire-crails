# Ported 1:1 from ~/once-campfire (Rails).
class ChangeActiveToStatusOnUsers < ActiveRecord::Migration
  def change
    add_column :users, :status, :integer, default: 0, null: false

    reversible do |dir|
      dir.up do
        execute "UPDATE users SET status = 1 WHERE active = 0"
      end
    end

    remove_column :users, :active, :boolean
  end
end

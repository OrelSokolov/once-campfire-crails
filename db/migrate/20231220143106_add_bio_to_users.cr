# Ported 1:1 from ~/once-campfire (Rails).
class AddBioToUsers < ActiveRecord::Migration
  def change
    change_table :users do |t|
      t.text :bio
    end
  end
end

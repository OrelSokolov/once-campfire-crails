# Ported 1:1 from ~/once-campfire (Rails). type: :integer matches the
# integer FK columns the Rails sqlite3 database declares.
class CreateBans < ActiveRecord::Migration
  def change
    create_table :bans do |t|
      t.references :user, null: false, foreign_key: true, type: :integer
      t.string :ip_address, null: false
      t.timestamps
    end

    add_index :bans, :ip_address
  end
end

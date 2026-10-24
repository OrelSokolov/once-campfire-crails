class CreateWebhooks < ActiveRecord::Migration
  def change
    create_table :webhooks do |t|
      t.references :user, null: false, foreign_key: true, type: :integer
      t.string :url

      t.timestamps
    end
  end
end

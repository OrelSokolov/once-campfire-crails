class CreateWebhooks < ActiveRecord::Migration[7.2]
  def change
    create_table :webhooks do |t|
      t.references :user, null: false, foreign_key: true, type: :integer
      t.string :url

      t.timestamps
    end
  end
end

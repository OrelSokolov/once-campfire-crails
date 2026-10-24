# Ported from ~/once-campfire (Rails, active_storage). The initial schema
# migration already creates the table — if_not_exists makes this a no-op,
# like the original (table_exists? guard + if_not_exists: true).
class CreateActiveStorageVariantRecords < ActiveRecord::Migration[6.0]
  def change
    return unless table_exists?(:active_storage_blobs)

    create_table :active_storage_variant_records, if_not_exists: true do |t|
      t.belongs_to :blob, null: false, index: false, type: :bigint
      t.string :variation_digest, null: false

      t.index [ "blob_id", "variation_digest" ], name: "index_active_storage_variant_records_uniqueness", unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end
  end
end

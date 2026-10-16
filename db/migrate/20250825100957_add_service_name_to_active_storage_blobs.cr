# Ported from ~/once-campfire (Rails, active_storage). The original
# backfills service_name from the configured storage service — on a fresh
# database there are no blobs yet, so the port is schema-only.
class AddServiceNameToActiveStorageBlobs < ActiveRecord::Migration
  def up
    return unless table_exists?(:active_storage_blobs)

    unless column_exists?(:active_storage_blobs, :service_name)
      add_column :active_storage_blobs, :service_name, :string
      change_column_null :active_storage_blobs, :service_name, false
    end
  end

  def down
    return unless table_exists?(:active_storage_blobs)

    remove_column :active_storage_blobs, :service_name
  end
end

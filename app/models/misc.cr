class Account < ActiveRecord::Base
  # Rails: has_one_attached :logo — логотип аккаунта (favicon,
  # accounts/logos_controller). Варианты :large(512)/:small(192) не
  # портированы (нет vips) — отдаётся оригинал вложения.
  def logo_attachment : ActiveStorageAttachment?
    ActiveStorageAttachment
      .where("record_type = ? AND record_id = ? AND name = ?", "Account", id.not_nil!, "logo")
      .take
  end

  def logo_blob : ActiveStorageBlob?
    logo_attachment.try do |attachment|
      ActiveStorageBlob.find(attachment.blob_id.not_nil!)
    end
  end
end

class Ban < ActiveRecord::Base
  belongs_to :user
end

class Boost < ActiveRecord::Base
  belongs_to :message
  belongs_to :booster, class_name: "User"
end

class Search < ActiveRecord::Base
  belongs_to :user
end

class Webhook < ActiveRecord::Base
  belongs_to :user
end

class PushSubscription < ActiveRecord::Base
  belongs_to :user
end

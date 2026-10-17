class Account < ActiveRecord::Base
  # Rails has_json :settings, restrict_room_creation_to_administrators:
  # false (account.rb:9) — доступ к флагу в jsonb settings без ручной
  # работы с JSON-строкой (parse → присваивание → dump).
  def restrict_room_creation_to_administrators? : Bool
    settings.try(&.["restrict_room_creation_to_administrators"]?.try(&.as_bool?)) == true
  end

  def restrict_room_creation_to_administrators=(value : Bool) : Nil
    # dup: as_h возвращает ссылку на хеш внутри JSON::Any — мутация на месте
    # сломала бы dirty-tracking (снапшот видит то же значение).
    base = settings.try(&.as_h.dup) || {} of String => JSON::Any
    base["restrict_room_creation_to_administrators"] = JSON::Any.new(value)
    self.settings = JSON::Any.new(base)
  end

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

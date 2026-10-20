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
  # accounts/logos_controller).
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

  # attachable.variant :large/:small (account.rb:4-7): resize_to_limit
  # 512/192, format png. logo_variant (account.rb:11-13) —
  # logo.variant(size).processed при variable?; nil (нет вложения /
  # не-variable тип / ошибка vips-обработки) — контроллер отдаёт
  # сток-иконку. Blob — шардовый ActiveStorage::Blob (variant/variable?
  # живут там, ср. create_and_upload! в MessageCreator).
  LOGO_VARIANT_SIZES = {"large" => [512, 512], "small" => [192, 192]}

  def logo_variant(size : String = "large") : ActiveStorage::Variant?
    attachment = logo_attachment
    return nil unless attachment
    blob = ActiveStorage::Blob.find?(attachment.blob_id.not_nil!)
    return nil unless blob && blob.variable?
    dims = LOGO_VARIANT_SIZES[size]? || LOGO_VARIANT_SIZES["large"]
    blob.variant(resize_to_limit: dims, format: "png").processed
  rescue ex : Exception
    nil
  end
end

class Ban < ActiveRecord::Base
  belongs_to :user
end

class Boost < ActiveRecord::Base
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User"
end

class Search < ActiveRecord::Base
  belongs_to :user
end

class Webhook < ActiveRecord::Base
  belongs_to :user
end

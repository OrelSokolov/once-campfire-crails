class Room < ActiveRecord::Base
  has_many :memberships, foreign_key: "room_id"
  has_many :messages, foreign_key: "room_id"
  belongs_to :creator, class_name: "User"

  # room.rb референса: opens/closeds/directs/without_directs/ordered.
  # Референс — equality по type ('Rooms::Open'); STI-порт хранит два
  # написания (сид — 'Rooms::Open', создание портом — короткое 'Open'),
  # поэтому условие расширено до IN обеих форм.
  scope(:opens)           { where("type IN ('Open', 'Rooms::Open')") }
  scope(:closeds)         { where("type IN ('Closed', 'Rooms::Closed')") }
  scope(:directs)         { where("type IN ('Direct', 'Rooms::Direct')") }
  scope(:without_directs) { where("type NOT IN ('Direct', 'Rooms::Direct')") }
  scope(:ordered)         { order("LOWER(name)") }

  # GlobalID STI-референса: gid строится от класса записи (Rooms::Open/
  # Rooms::Direct/Rooms::Closed), а не от кристалловского Room — иначе
  # расходится signed-stream-name turbo-cable-stream-source. type хранит
  # и полный ('Rooms::Open', сид), и короткий ('Open', создание портом)
  # вариант — нормализуем к полному.
  def to_gid_param : String
    sti = type.to_s
    sti = "Rooms::#{sti}" unless sti.includes?("::")
    gid = "gid://#{Turbo.app}/#{sti}/#{id.not_nil!}"
    Base64.urlsafe_encode(gid, padding: false)
  end

  # dom_id референса: Rooms::Open → rooms_open_<id> (model_name.param_key).
  def dom_id : String
    sti = type.to_s.split("::")[-1].underscore
    "rooms_#{sti}_#{id.not_nil!}"
  end

  # Direct-комната (ping): name IS NULL. Детект по имени, а не type —
  # type хранит два написания ('Rooms::Direct' сид, 'Direct' создание
  # портом), все SQL-запросы порта фильтруют так же (WHERE r.name IS NULL).
  def direct? : Bool
    name.nil?
  end

  # Visible rooms for a user, involvement-filtered (sidebar listing).
  scope(:visible, ->(user) {
    where(%(id IN (SELECT room_id FROM memberships WHERE user_id = ? AND involvement != 'invisible')),
      user.id.not_nil!)
  })

  def self.visible_for(user : User)
    visible(user)
  end
end

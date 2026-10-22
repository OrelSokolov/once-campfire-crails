# Отклонения от Rails-стиля, не реализуемые (или отложенные) на Crystal

Фиксация по требованию AGENTS.md: «если что-то не получается реализовать —
добавляй в записки». Базлайн — `twinshot review code`.

## Синтаксис Crystal (не воспроизводится в принципе)

- **`private`-секция с отступом** (`private` + indented `def`) — Crystal
  допускает только `private def foo` в одну строку.
- **`include A, B, C` одной строкой** — Crystal требует отдельный `include`
  на каждый модуль.
- **`%i[ show destroy ]`-литералы** — только `[:show, :destroy]`.
- **`class << self` / `extend ActiveSupport::Concern`** — модули Crystal
  подключаются напрямую, concern-механика не нужна.

## Требуют патчей шардов (план, Фаза 7)

- **`ActiveRecord::Migration[8.1]`** — нужен class-method `self.[]`
  в `active_record_cr` (миграции после этого 1:1 с оракулом).
- **`render layout: "rooms/layouts/new" do ... end`** в шаблонах —
  layout-партиал с блоком; сейчас вьюхи инлайнят
  `render partial: ..., locals: {...}` (compile_partials).
- **`has_many ... do ... end` (extension-блоки ассоциаций)** —
  `Room#memberships.grant_to/revoke_from/revise`; компромисс:
  class-методы `Membership`.

## Осознанные отклонения (behavior/инфраструктура)

- **`icon()` вместо `image_tag "x.svg"`** — пребилд-манифест даёт
  `/assets/<fingerprinted>` src; `image_tag` с голым именем выдал бы
  `/images/x.svg` и сломал бы byte-parity HTML.
- **`form_with url: "/account.#{id}"` вместо `form_with model:`** — механика
  есть (railties_cr подключает `FormHelper.polymorphic_path`), но замена
  отложена: URL и сконы форм должны совпасть до байта.
- **`boosts_dom` вместо `render "messages/boosts/boosts"`** — HTML
  сообщения/бустов собирает ChatLayout (compile-time), view-уровневого
  `render`-партиала в порте нет.
- **Комментарии-шапки на русском** — в оракуле их нет; контрактные
  пояснения (PageCache/IdentityCache, byte-parity ловушки) оставлены —
  их удаление без переноса куда-либо потеряло бы контекст порта.

## Выравнивания поведения (сделано, отличалось от оракула)

- `RoomsController#set_room`: раньше 404 "Room not found" на чужую/несущ.
  комнату → теперь membership-scope + `redirect_to root_path, alert:`
  как в оракуле.
- `MessagesController` edit/update/destroy: раньше «только автор» с телом
  403 "Cannot edit/delete this message" → теперь `ensure_can_administer`
  (автор или админ, пустой 403) как в оракуле.
- `by_bots` update/destroy: аналогично — `ensure_can_administer` вместо
  проверки только создателя.
- `Rooms::Opens/Closeds#edit/update` на несуществующую комнату: раньше
  head 404 → теперь redirect через set_room (как в оракуле).

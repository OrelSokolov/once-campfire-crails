# BoostsHelpers — ERB-хелперы app/views/messages/boosts/*.html.erb
# (index/new). Включается в Messages::BoostsController; общий icon —
# ViewHelpers.
module BoostsHelpers
  # index.html.erb: boosts partial. Файл шаблона — без завершающего
  # перевода строки после <%= boosts_dom %> (byte-parity с референсом:
  # boosts_dom сам завершает вывод "\n").
  def boosts_dom : ERB::SafeString
    ERB::SafeString.new(ChatLayout.boosts_dom(mid.not_nil!, boosts))
  end
end

# Used to match JavaScripts (new Date).getTime() for sorting
# (config/initializers/time_formats.rb оракула). Rails-лямбда возвращает
# Integer и to_fs делает #to_s — в Crystal блок реестра возвращает String
# сразу (Int64: миллисекунды не влезают в Int32).
ActiveSupport::TimeFormats.register(:epoch, ->(time : Time) {
  ((time.to_f * 1000).to_i64).to_s
})

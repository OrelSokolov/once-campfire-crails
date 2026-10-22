# Loaded when CRails.env == "production"
if CRails.env.production?
  # HTTP_PORT comes from the bench harness (compare.rb config).
  if (port = ENV["HTTP_PORT"]?)
    CRails.application.config.port = port.to_i
  end

  # production.rb:84-85 оракула: assume_ssl/force_ssl (HSTS + редирект
  # на https), пока не задан DISABLE_SSL — harness-прогоны и локальный
  # запуск идут по plain http за прокси без TLS.
  if ENV["DISABLE_SSL"]?.to_s.empty?
    CRails.application.config.assume_ssl = true
    CRails.application.config.force_ssl = true
  end
end

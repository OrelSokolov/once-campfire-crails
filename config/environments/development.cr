# Loaded when CRails.env == "development"
if CRails.env.development?
  CRails.application.config.port = 3000
end

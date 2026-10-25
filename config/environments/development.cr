# Loaded when CRails.env == "development"
if CRails.env.development?
  CRails.application.configure do |config|
    config.port = 3000
  end
end

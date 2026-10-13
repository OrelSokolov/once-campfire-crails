# Loaded when CRails.env == "production"
if CRails.env.production?
  # HTTP_PORT comes from the bench harness (compare.rb config).
  if (port = ENV["HTTP_PORT"]?)
    CRails.application.config.port = port.to_i
  end
end

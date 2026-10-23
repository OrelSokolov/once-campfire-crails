# version_headers.rb: X-Version/X-Rev в каждом ответе (version.rb
# инициализатор оракула: APP_VERSION || GIT_REVISION || "0").
module VersionHeaders
  private def set_version_headers : Nil
    response.headers["X-Version"] = ENV["APP_VERSION"]? || ENV["GIT_REVISION"]? || "0"
    response.headers["X-Rev"] = ENV["GIT_REVISION"]? || "0"
  end
end

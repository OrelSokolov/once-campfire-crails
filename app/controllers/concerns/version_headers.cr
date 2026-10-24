module VersionHeaders
  private def set_version_headers : Nil
    response.headers["X-Version"] = ENV["APP_VERSION"]? || ENV["GIT_REVISION"]? || "0"
    response.headers["X-Rev"] = ENV["GIT_REVISION"]? || "0"
  end
end

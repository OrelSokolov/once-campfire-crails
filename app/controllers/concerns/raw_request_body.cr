module RawRequestBody
  private def raw_request_body : String
    request.body.try(&.gets_to_end).to_s
  end
end

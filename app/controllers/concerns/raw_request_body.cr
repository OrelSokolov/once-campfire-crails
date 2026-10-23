# raw_request_body.rb: сырая строка тела запроса (боты шлют JSON/text
# без form-encoding).
module RawRequestBody
  private def raw_request_body : String
    request.body.try(&.gets_to_end).to_s
  end
end

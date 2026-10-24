class UnfurlLinksController < ApplicationController
  # The pasted link decides which hosts an unfurl looks up and fetches from, and how quickly they answer.
  DEADLINE = 10.0

  def create
    url = params["url"]?.to_s
    if url.empty?
      return render(plain: "", status: :bad_request)
    end

    if opengraph = unfurl(url)
      render(json: opengraph.to_json)
    else
      render(plain: "", status: :no_content)
    end
  end

  # One deadline for everything the link leads to: DNS lookups, redirects, the page, the image check.
  # The deadline is passed down (the remaining budget goes to each connect/read/write).
  private def unfurl(url : String) : Opengraph::Metadata?
    deadline = Time.instant + DEADLINE.seconds
    opengraph = Opengraph::Metadata.from_url(url, deadline)
    opengraph if opengraph.valid?
  rescue ex
    nil
  end
end

# Health check: the bench harness waits for readiness on /up
# (contract: 200, body contains "background-color: green").
# Public — the harness polls it before logging in.
class UpController < ApplicationController
  allow_unauthenticated_access

  def show
    render(html: <<-HTML
      <!doctype html>
      <html><head><style>body { background-color: green; }</style></head>
      <body>OK</body></html>
    HTML
    )
  end
end

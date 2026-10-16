# frozen_string_literal: true

require_relative "../test_helper"

class MiscTest < ParityTest
  def test_up_reports_readiness
    visit "/up"
    refute_empty page.body
    assert_match(/green/i, page.body)
  end

  def test_unknown_page_returns_404
    visit "/parity-nowhere"
    assert_equal 404, page.status_code
    settled_snap("404")
  end
end

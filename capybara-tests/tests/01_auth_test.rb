# frozen_string_literal: true

require_relative "../test_helper"
require "net/http"

class AuthTest < ParityTest
  def test_login_page_renders
    visit "/session/new"
    assert_selector "[name='email_address']"
    assert_selector "[name='password']"
    settled_snap("login")
  end

  def test_wrong_password_shows_error
    visit "/session/new"
    fill_in "email_address", with: Parity::EMAILS.fetch(:david)
    fill_in "password", with: "definitely-not-it"
    find("button[name='log_in']").click
    # The form re-renders with the email retained (401 path); the email lives
    # in the DOM value either way.
    assert_selector "input[name='email_address']", wait: 10
    assert_equal Parity::EMAILS.fetch(:david), find("input[name='email_address']").value
    # The flash element removes itself on animationend in the browser, so
    # verify the rejection response itself: 401 with the alert markup.
    cookies = cookie_header
    page2 = Net::HTTP.start(URI(Parity.base_url).host, URI(Parity.base_url).port) { |http| http.get("/session/new", { "cookie" => cookies }) }
    csrf = page2.body[/name="csrf-token" content="([^"]+)"/, 1]
    request = Net::HTTP::Post.new("/session")
    request.set_form_data({ "email_address" => Parity::EMAILS.fetch(:david), "password" => "definitely-not-it", "authenticity_token" => csrf.to_s })
    request["cookie"] = cookies
    response = Net::HTTP.start(URI(Parity.base_url).host, URI(Parity.base_url).port) { |http| http.request(request) }
    assert_equal 401, response.code.to_i, "wrong password must render the 401 form"
    assert_includes response.body, "Too many requests or unauthorized."
    settled_snap("login-error")
  end

  def test_banned_user_cannot_sign_in
    visit "/session/new"
    fill_in "email_address", with: Parity::EMAILS.fetch(:mallory)
    fill_in "password", with: Parity::PASSWORD
    find("button[name='log_in']").click
    assert_selector "[name='email_address']" # back on the form
    settled_snap("login-banned")
  end

  def test_sign_in_lands_in_a_room
    sign_in_through_ui!(Parity::EMAILS.fetch(:david))
    assert_selector "lexxy-editor#message_body"
    settled_snap("after-login")
  end

  def test_root_redirects_signed_in_user_to_a_room
    sign_in_as!(:david)
    visit "/"
    assert_current_path(%r{/rooms/\d+\z})
    assert_selector "lexxy-editor#message_body"
  end

  def test_signed_out_root_redirects_to_login
    visit "/"
    assert_current_path(%r{/session/new})
    assert_selector "[name='email_address']"
  end

  def test_sign_out_returns_to_login
    # Use a dedicated UI session so terminating it does not kill the shared
    # programmatic david session used by the rest of the suite.
    sign_in_through_ui!(Parity::EMAILS.fetch(:david))
    visit "/users/me/profile"
    # Sign-out is a DELETE form on the profile page.
    within("form[action='/session']") { find("button, input[type='submit']").click }
    assert_current_path(%r{/session/new|\A/\z}, wait: 15)
    assert_selector "[name='email_address']", wait: 10
    settled_snap("after-logout")
  end
end

# frozen_string_literal: true

require_relative "../test_helper"

class ProfileTest < ParityTest
  def setup
    sign_in_as!(:david)
  end

  def test_own_profile_page_renders
    visit "/users/me/profile"
    assert_selector "[name='user[email_address]']", wait: 10
    settled_snap("profile")
  end

  def test_editing_the_bio_persists
    visit "/users/me/profile"
    fill_in "user[bio]", with: "Parity-run bio"
    click_on "Save changes"
    assert_equal "Parity-run bio", find("[name='user[bio]']").value, wait: 10
    visit "/users/me/profile"
    assert_equal "Parity-run bio", find("[name='user[bio]']").value
    settled_snap("profile-edited")
  end

  def test_avatar_endpoint_serves_deterministic_bytes
    dir = Parity::Snap.dir_for(self)
    FileUtils.mkdir_p(dir)
    token = Parity::AVATAR_TOKENS.fetch(:david)
    uri = URI("#{Parity.base_url}/users/#{token}/avatar")
    cookies = cookie_header
    require "net/http"
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.get(uri.path, { "cookie" => cookies }) }
    assert_equal 200, response.code.to_i
    assert_match(%r{^image/}, response["content-type"])
    File.binwrite(File.join(dir, "avatar-david.png"), response.body)
  end

  def test_colleague_profile_with_uploaded_avatar_renders
    visit "/users/#{Parity::LABELS.fetch('users.jason')}"
    assert_selector "img", wait: 10
    settled_snap("profile-jason")
  end

  def test_session_transfer_url_signs_in_a_fresh_browser
    visit "/users/me/profile"
    transfer_url = find("#session_transfer_url").value
    assert_match(%r{/session/transfers/}, transfer_url)

    Capybara.using_session("transfer-fresh") do
      visit transfer_url
      assert_current_path(%r{/rooms/\d+\z}, wait: 15)
      visit "/users/me/profile"
      assert_selector "[name='user[email_address]'][value='#{Parity::EMAILS.fetch(:david)}']"
    end
  end

  def test_expired_session_transfer_is_rejected
    Capybara.using_session("expired-transfer") do
      visit "/session/transfers/#{Parity::TRANSFERS.fetch(:david_expired)}"
      # Seed tokens expired in March 2026: give any auto-login redirect time to
      # fire, then require that we did not land in a room.
      sleep 2
      refute_match(%r{/rooms/\d+\z}, page.current_url, "expired transfer must not sign in")
      settled_snap("expired-transfer")
    end
  end
end

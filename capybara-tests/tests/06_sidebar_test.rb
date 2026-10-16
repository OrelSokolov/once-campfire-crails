# frozen_string_literal: true

require_relative "../test_helper"

class SidebarTest < ParityTest
  def setup
    sign_in_as!(:david)
  end

  def test_sidebar_lists_shared_and_direct_rooms
    open_room!(Parity::ROOMS.fetch(:hq))
    assert_selector "#shared_rooms a", wait: 5
    assert_selector "#direct_rooms_control a, #direct_rooms a", wait: 5
    settled_snap("sidebar")
  end

  def test_switching_rooms_via_the_sidebar
    open_room!(Parity::ROOMS.fetch(:hq))
    find("#shared_rooms a[href*='/rooms/#{Parity::ROOMS.fetch(:pets)}']").click
    assert_current_path(%r{/rooms/#{Parity::ROOMS.fetch(:pets)}})
    assert_selector "lexxy-editor#message_body"
    settled_snap("switched-to-pets")
  end

  def test_sidebar_fragment_endpoint_returns_the_same_markup
    open_room!(Parity::ROOMS.fetch(:hq))
    refute_empty page.body # sanity: page loaded
    # Fetch the fragment through a plain authenticated request.
    uri = URI("#{Parity.base_url}/users/me/sidebar")
    cookies = cookie_header
    require "net/http"
    html = Net::HTTP.start(uri.host, uri.port) { |http| http.get(uri.path, { "cookie" => cookies }).body }
    dir = Parity::Snap.dir_for(self)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "sidebar-fragment.html"), Parity::Normalize.html(html, Parity.base_url))
  end

  def test_narrow_viewport_renders_the_mobile_layout
    page.driver.browser.resize(width: 390, height: 844)
    open_room!(Parity::ROOMS.fetch(:hq))
    settled_snap("mobile")
  ensure
    page.driver.browser.resize(width: 1400, height: 1400)
  end

  def test_member_of_no_rooms_sees_the_welcome_page
    sign_in_as!(:lou)
    visit "/"
    assert_text "Lonely Lou", wait: 5 # welcome screen greets the user by name
    settled_snap("welcome")
  end
end

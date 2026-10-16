# frozen_string_literal: true

require_relative "../test_helper"

class AccountTest < ParityTest
  def setup
    sign_in_as!(:david)
  end

  def test_account_settings_page_renders
    visit "/account/edit"
    assert_selector "[name='account[name]']", wait: 10
    settled_snap("account")
  end

  def test_bots_page_lists_active_bots
    visit "/account/bots"
    assert_text "Bender"
    assert_text "Deploy Bot"
    # The curl lines embed the run's random port; hide them from the PNG
    # (the HTML artifact keeps them, port-normalized).
    Parity::Snap.hide_volatile(page, ["input[aria-label='curl command for posting messages']",
                                      "input[aria-label='curl command for posting attachments']"])
    settled_snap("bots")
  end

  def test_new_bot_page_renders
    visit "/account/bots/new"
    assert_selector "[placeholder='Name the bot']", wait: 10
    settled_snap("bot-new")
  end

  def test_creating_a_bot_yields_a_working_posting_url
    visit "/account/bots/new"
    fill_in placeholder: "Name the bot", with: "Parity Bot"
    click_on "Save changes"
    assert_current_path(%r{/account/bots\z})
    command = find("[aria-label='curl command for posting messages'], textarea", match: :first).value
    bot_url = command.scan(%r{https?://\S+}).last
    refute_nil bot_url
    uri = URI(bot_url)
    posted = Net::HTTP.start(uri.host, uri.port) do |http|
      request = Net::HTTP::Post.new(uri.request_uri)
      request.body = "Hello from parity bot"
      http.request(request)
    end
    assert posted.is_a?(Net::HTTPSuccess), "bot post failed: #{posted.code}"
    open_room!(Parity::ROOMS.fetch(:watercooler))
    message_with_text!("Hello from parity bot")
    settled_snap("bot-posted", mask_times: true)
  end

  def test_custom_styles_apply_to_every_page
    visit "/account/custom_styles/edit"
    fill_in "account[custom_styles]", with: "body { --parity-marker: applied; }"
    find("form:has(textarea[name='account[custom_styles]']) button").click
    page.execute_script <<~JS
      const apply = () => {
        if (getComputedStyle(document.body).getPropertyValue("--parity-marker").trim() === "applied") return true
      }
    JS
    assert_selector "[name='account[custom_styles]']", wait: 10
    # Let the turbo form redirect finish racing before navigating on.
    begin
      page.driver.browser.network.wait_for_idle(timeout: 3)
    rescue StandardError
      nil
    end
    visit "/account/edit"
    value = page.evaluate_script("getComputedStyle(document.body).getPropertyValue('--parity-marker').trim()")
    assert_equal "applied", value
    settled_snap("custom-styles")
  end

  def test_invitation_url_lets_a_newcomer_join
    visit "/account/edit"
    invite_input = find("#invite_url", match: :first) rescue nil
    invite_url = invite_input&.value
    invite_url ||= "#{Parity.base_url}/join/#{Parity::JOIN_CODE}"

    Capybara.using_session("newcomer") do
      visit invite_url
      assert_selector "[name='user[name]']", wait: 10
      fill_in "user[name]", with: "Parity Newcomer"
      fill_in "user[email_address]", with: "newcomer@example.test"
      fill_in "user[password]", with: "parity-join-password"
      within("form:has(input[name='user[name]'])") { find("button[type='submit']").click }
      assert_current_path(%r{/rooms/\d+\z}, wait: 15)
      visit "/account/edit"
      assert_no_selector "a", text: "Set up chat bots" # members do not see admin controls
    end
  end
end

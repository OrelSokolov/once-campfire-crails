# frozen_string_literal: true

require_relative "../test_helper"

# Live Action Cable behavior across two signed-in browser sessions.
class LiveTest < ParityTest
  def setup
    sign_in_as!(:david)
    open_room!(Parity::ROOMS.fetch(:hq))
  end

  def test_messages_flow_between_two_sessions_without_duplicates
    Capybara.using_session("live-jason") do
      sign_in_as!(:jason)
      open_room!(Parity::ROOMS.fetch(:hq))
    end

    send_message!("Live: hello from david")
    Capybara.using_session("live-jason") { message_with_text!("Live: hello from david") }

    Capybara.using_session("live-jason") do
      send_message!("Live: reply from jason")
    end
    message_with_text!("Live: reply from jason")

    [self, "live-jason"].each do |context|
      Capybara.using_session(context.is_a?(String) ? context : :default) do
        # Count the exact texts: other live tests also post "Live:*" to HQ.
        assert_equal 1, all(".message[data-message-id]", text: "Live: hello from david").size, "expected no duplicate live messages"
        assert_equal 1, all(".message[data-message-id]", text: "Live: reply from jason").size
      end
    end
    settled_snap("two-tabs", mask_times: true)
  ensure
    Capybara.using_session("live-jason") { Capybara.reset_sessions! } rescue nil
  end

  def test_edits_propagate_to_the_other_session
    send_message!("Live: edit me")
    Capybara.using_session("live-jason") do
      sign_in_as!(:jason)
      open_room!(Parity::ROOMS.fetch(:hq))
      message_with_text!("Live: edit me")
    end

    message = message_with_text("Live: edit me")
    message.find("summary").click
    message.find(".message__edit-btn").click
    editor = message.find("[aria-label='Edit message']", match: :first)
    editor.click
    page.execute_script(<<~JS)
      const editor = document.querySelector("[aria-label='Edit message']")
      editor.value = "Live: edited live"
      editor.dispatchEvent(new Event("input", { bubbles: true }))
    JS
    message.find("button", text: /Save/).click
    # On the authoring session the edited message re-renders through a lazy
    # edit turbo-frame; wait for it to load so the snapshot is stable.
    within(message_with_text("Live: edited live")) do
      assert_selector "turbo-frame[id^='edit_message_'][complete]", wait: 10
    end
    Capybara.using_session("live-jason") do
      # The edit arrives here as a stream-rendered message (no lazy frame).
      message_with_text!("Live: edited live")
    end
    settled_snap("live-edit", mask_times: true)
  ensure
    Capybara.using_session("live-jason") { Capybara.reset_sessions! } rescue nil
  end

  def test_boosts_propagate_to_the_other_session
    send_message!("Live: boost me")
    Capybara.using_session("live-jason") do
      sign_in_as!(:jason)
      open_room!(Parity::ROOMS.fetch(:hq))
      message = message_with_text("Live: boost me")
      message.find("summary").click
      message.find("[data-emoji='👍']").click
      assert_selector ".boost", wait: 10
    end
    message_with_text!("Live: boost me")
    assert_selector ".boost", wait: 10
    settled_snap("live-boost", mask_times: true)
  ensure
    Capybara.using_session("live-jason") { Capybara.reset_sessions! } rescue nil
  end

  def test_deletes_propagate_to_the_other_session
    send_message!("Live: delete me")
    Capybara.using_session("live-jason") do
      sign_in_as!(:jason)
      open_room!(Parity::ROOMS.fetch(:hq))
      message_with_text!("Live: delete me")
    end

    message = message_with_text("Live: delete me")
    message.find("summary").click
    message.find(".message__edit-btn").click
    # Deletion lives inside the open editor: a button wired to the delete form.
    accept_confirm do
      message.find("button[form^='delete_form_']").click
    end
    assert_no_selector ".message[data-message-id]", text: "Live: delete me", wait: 10
    Capybara.using_session("live-jason") do
      assert_no_selector ".message[data-message-id]", text: "Live: delete me", wait: 10
    end
    settled_snap("live-delete", mask_times: true)
  ensure
    Capybara.using_session("live-jason") { Capybara.reset_sessions! } rescue nil
  end

  def test_new_room_appears_live_in_another_sessions_sidebar
    Capybara.using_session("live-jason") do
      sign_in_as!(:jason)
      open_room!(Parity::ROOMS.fetch(:hq))
    end

    visit "/rooms/opens/new"
    fill_in placeholder: "Name the room", with: "Live Parity Room"
    find("form button[type='submit']").click
    assert_current_path(%r{/rooms/\d+\z})

    Capybara.using_session("live-jason") do
      assert_selector "#shared_rooms a", text: "Live Parity Room", wait: 15
    end
    settled_snap("live-room-sidebar", mask_times: true)
  ensure
    # Delete the room again: open rooms appear for every member, which would
    # break SidebarTest's no-rooms welcome expectations for lou. Must run
    # before any session reset — the default session holds the room page.
    begin
      click_on "Settings for this room"
      accept_confirm { find("button[aria-label='Delete Live Parity Room']").click }
      assert_current_path(%r{\A/rooms/\d+|/\z}, wait: 10)
    rescue StandardError => e
      warn "live room cleanup failed: #{e.class}: #{e.message}"
    end
    Capybara.using_session("live-jason") { Capybara.reset_sessions! } rescue nil
  end

  def test_unread_badge_updates_live_for_an_away_member
    open_room!(Parity::ROOMS.fetch(:pets)) # david sits outside watercooler
    Capybara.using_session("live-jason") do
      sign_in_as!(:jason)
      open_room!(Parity::ROOMS.fetch(:watercooler))
      send_message!("Live: unread ping")
    end
    sleep 2 # cable broadcast → sidebar refresh
    settled_snap("live-unread", mask_times: true)
  ensure
    Capybara.using_session("live-jason") { Capybara.reset_sessions! } rescue nil
  end
end

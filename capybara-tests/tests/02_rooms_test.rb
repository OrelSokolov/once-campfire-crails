# frozen_string_literal: true

require_relative "../test_helper"

class RoomsTest < ParityTest
  def setup
    sign_in_as!(:david)
  end

  def test_empty_hq_room_renders
    open_room!(Parity::ROOMS.fetch(:hq))
    assert_selector "h1, [data-room-name]", text: "HQ", wait: 5
    settled_snap("hq")
  end

  def test_designers_renders_every_presentation_type
    open_room!(Parity::ROOMS.fetch(:designers))
    assert_selector ".message[data-message-id]", text: "Morning! Anyone around?"
    assert_selector ".message[data-message-id]", text: "def greet(name)"
    assert_selector ".message[data-message-id]", text: "Launch is on the 16th."
    assert_selector ".message[data-message-id]", text: "Big news: the beta is open!"
    settled_snap("designers")
  end

  def test_watercooler_pages_through_history_on_scroll
    open_room!(Parity::ROOMS.fetch(:watercooler))
    8.times do
      break if page.has_selector?(".message[data-message-id]", text: "001.", visible: :all, wait: 2)

      # `.messages` is the actual overflow container inside `#message-area`.
      page.execute_script <<~JS
        const area = document.querySelector(".messages") || document.querySelector("#message-area") || document.scrollingElement
        area ? area.scrollTo(0, 0) : window.scrollTo(0, 0)
      JS
      sleep 0.8
    end
    assert_selector ".message[data-message-id]", text: "001. Coffee machine is fixed!", visible: :all
    settled_snap("watercooler-paged", mask_times: true)
  end

  def test_deep_link_to_a_message_anchors_it
    visit "/rooms/#{Parity::ROOMS.fetch(:designers)}/@#{Parity::MESSAGES.fetch(:boosted_one)}"
    assert_selector ".message[data-message-id='#{Parity::MESSAGES.fetch(:boosted_one)}']"
    settled_snap("deeplink")
  end

  def test_room_settings_page_renders
    open_room!(Parity::ROOMS.fetch(:hq))
    click_on "Settings for this room"
    assert_selector "input[name='room[name]']", wait: 10
    settled_snap("room-settings")
  end

  def test_closed_room_renders_for_its_member
    open_room!(Parity::ROOMS.fetch(:quiet))
    assert_selector "h1, [data-room-name], .message-area", wait: 5
    settled_snap("quiet-corner")
  end

  def test_broken_room_survives_a_missing_author
    open_room!(Parity::ROOMS.fetch(:broken))
    # The message's creator is gone: rendering raises and the partial's rescue
    # swaps in the failure placeholder instead of a data-message-id message.
    assert_selector ".message--failed", text: "Failed to load message content", wait: 5
    assert_selector "lexxy-editor#message_body" # the room itself still works
    settled_snap("broken-room")
  end

  def test_unread_room_is_marked_in_the_sidebar
    open_room!(Parity::ROOMS.fetch(:hq))
    assert_selector "#shared_rooms a[href*='/rooms/#{Parity::ROOMS.fetch(:watercooler)}']", wait: 5
    settled_snap("unread-badge")
  end
end

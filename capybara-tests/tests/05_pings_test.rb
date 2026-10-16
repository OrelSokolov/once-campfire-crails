# frozen_string_literal: true

require_relative "../test_helper"

class PingsTest < ParityTest
  def setup
    sign_in_as!(:david)
  end

  def test_direct_room_with_a_colleague_renders
    open_room!(Parity::ROOMS.fetch(:david_and_jason))
    assert_selector ".message[data-message-id]", text: "The pricing page. Let's talk after lunch."
    settled_snap("dm-jason")
  end

  def test_group_direct_room_renders
    open_room!(Parity::ROOMS.fetch(:group_direct))
    assert_selector ".message[data-message-id]", text: "Group ping: who's in for Thursday?"
    settled_snap("dm-group")
  end

  def test_bot_direct_room_renders
    sign_in_as!(:kevin) # bender_and_kevin is kevin's DM with the bot
    open_room!(Parity::ROOMS.fetch(:bender_and_kevin))
    assert_selector ".message[data-message-id]", text: "Your nightly report is ready."
    settled_snap("dm-bot")
  end

  def test_unread_direct_rooms_are_ordered_and_badged_in_the_sidebar
    open_room!(Parity::ROOMS.fetch(:hq))
    assert_selector "a[href*='/rooms/#{Parity::ROOMS.fetch(:david_and_kevin)}']", wait: 5
    settled_snap("dm-sidebar")
  end
end

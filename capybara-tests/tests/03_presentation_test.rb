# frozen_string_literal: true

require_relative "../test_helper"

# Element-level snapshots of every message presentation type in Designers.
class PresentationTest < ParityTest
  def setup
    sign_in_as!(:david)
    open_room!(Parity::ROOMS.fetch(:designers))
  end

  def message_selector(label)
    "[data-message-id='#{Parity::MESSAGES.fetch(label)}']"
  end

  def test_plain_message
    assert_selector message_selector(:plain)
    snap_element("plain", message_selector(:plain))
  end

  def test_rich_formatting
    assert_selector ".message[data-message-id]", text: "underlined"
    snap_element("formatting", ".message[data-message-id]", ) # full message row for context
  end

  def test_code_block_with_language
    assert_selector ".message[data-message-id]", text: "def greet(name)"
    snap_element("code", message_selector(:code))
  end

  def test_table_message
    assert_selector ".message[data-message-id]", text: "Programming"
    snap_element("table", ".message[data-message-id]")
  end

  def test_mention_renders_the_mentioned_user
    assert_selector ".message[data-message-id]", text: "can you check the table above?"
    snap_element("mention", message_selector(:mention))
  end

  def test_opengraph_unfurl_card
    assert_selector ".message[data-message-id]", text: "Free cookies for everyone"
    snap_element("opengraph", ".message[data-message-id]")
  end

  def test_image_attachment
    snap_element("image-attachment", message_selector(:image))
  end

  def test_video_attachment
    snap_element("video-attachment", message_selector(:video))
  end

  def test_file_attachment
    assert_selector ".message[data-message-id]", text: "launch-notes.txt"
    snap_element("file-attachment", message_selector(:file))
  end

  def test_boost_row_with_emoji_and_text_boosts
    selector = message_selector(:boosted_many)
    assert_selector "#{selector} .boost", text: "Finally!"
    snap_element("boosts", selector)
  end

  def test_bot_message_styling
    assert_selector ".message[data-message-id]", text: "Deployed campfire@4f2c1e9"
    snap_element("bot-message", ".message[data-message-id]")
  end

  def test_message_by_a_deactivated_user
    assert_selector ".message[data-message-id]", text: "I'll be out of office next week."
    snap_element("deactivated-author", ".message[data-message-id]")
  end
end

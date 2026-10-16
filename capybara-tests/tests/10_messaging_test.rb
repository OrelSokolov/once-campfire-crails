# frozen_string_literal: true

require_relative "../test_helper"

# Message-authoring flows: composer, optimistic updates, editing, boosts,
# attachments. These mutate the database; identical steps on both targets.
class MessagingTest < ParityTest
  def setup
    sign_in_as!(:david)
    open_room!(Parity::ROOMS.fetch(:hq))
  end

  def test_sending_plain_text_reconciles_the_optimistic_message
    send_message!("Parity: plain hello")
    assert_no_selector "[data-pending-message]", wait: 10
    assert_equal 1, all(".message[data-message-id]", text: "Parity: plain hello").size
    settled_snap("sent-plain", mask_times: true)
  end

  def test_sending_rich_text_preserves_formatting
    set_editor_value("<div><strong>Parity bold</strong> and <em>parity italic</em></div>")
    find("button[name='send']").click
    message_with_text!("parity italic")
    settled_snap("sent-rich", mask_times: true)
  end

  def test_sending_a_code_block_preserves_the_pre
    set_editor_value("<pre>parity_one_two_three()</pre>")
    find("button[name='send']").click
    message_with_text!("parity_one_two_three")
    settled_snap("sent-code", mask_times: true)
  end

  def test_sending_a_link_autolinks_it
    set_editor_value("<div>Docs live at https://example.com/parity-docs</div>")
    find("button[name='send']").click
    message_with_text!("parity-docs")
    assert_selector ".message a[href='https://example.com/parity-docs']", wait: 10
    settled_snap("sent-link", mask_times: true)
  end

  def test_sending_emoji_text
    set_editor_value("<div>parity 🎉🔥 done</div>")
    find("button[name='send']").click
    message_with_text!("parity 🎉🔥 done")
    settled_snap("sent-emoji", mask_times: true)
  end

  def test_editing_own_message
    send_message!("Parity: edit me in place")
    message = message_with_text("Parity: edit me in place")
    message.find("summary").click
    message.find(".message__edit-btn").click
    page.execute_script(<<~JS)
      const editor = document.querySelector("[aria-label='Edit message']")
      editor.value = "Parity: edited in place"
      editor.dispatchEvent(new Event("input", { bubbles: true }))
    JS
    message.find("button", text: /Save/).click
    message_with_text!("Parity: edited in place")
    # The edited message re-renders through a lazy edit turbo-frame scoped to
    # that message; wait for it to load so the snapshot is stable.
    within(message_with_text("Parity: edited in place")) do
      assert_selector "turbo-frame[id^='edit_message_'][complete]", wait: 10
    end
    settled_snap("edited", mask_times: true)
  end

  def test_deleting_own_message
    send_message!("Parity: doomed")
    message = message_with_text("Parity: doomed")
    message.find("summary").click
    message.find(".message__edit-btn").click
    # Deletion lives inside the open editor: a button wired to the delete form.
    accept_confirm do
      message.find("button[form^='delete_form_']").click
    end
    assert_no_selector ".message[data-message-id]", text: "Parity: doomed", wait: 10
    settled_snap("deleted", mask_times: true)
  end

  def test_quick_boosting_with_an_emoji
    open_room!(Parity::ROOMS.fetch(:designers))
    message = message_with_text("Nobody boosted this one.")
    message.find("summary").click
    message.find("[data-emoji='👍']").click
    assert_selector ".boost", wait: 10
    settled_snap("quick-boost", mask_times: true)
  end

  def test_custom_boost_with_text
    open_room!(Parity::ROOMS.fetch(:designers))
    message = message_with_text("Nobody boosted this one.")
    message.find("summary").click
    message.find(".message__boost-btn").click
    # The boost input has no placeholder; target it inside the boost form.
    find(".boost__form input[type='text']").set("parity boost")
    find(".boost__form button[type='submit']").click
    assert_selector ".boost", text: "parity boost", wait: 10
    settled_snap("custom-boost", mask_times: true)
  end

  def test_reply_prefills_the_composer
    open_room!(Parity::ROOMS.fetch(:designers))
    message = message_with_text("Who's reviewing the copy?")
    message.find("summary").click
    message.find("button[aria-label='Reply']").click
    assert_selector "lexxy-editor#message_body"
    settled_snap("reply-prefill", mask_times: true)
  end

  def test_copying_a_message_permalink
    open_room!(Parity::ROOMS.fetch(:designers))
    message = message_with_text("Lunch is here.")
    numeric_id = message["data-message-id"]
    expected = "#{Parity.base_url}/rooms/#{Parity::ROOMS.fetch(:designers)}/@#{numeric_id}"
    value = page.evaluate_script("(() => {
      const expected = arguments[0]
      return document.querySelector(\"[data-message-id='#{numeric_id}'] [data-copy-to-clipboard-content-value]\")?.dataset.copyToClipboardContentValue
    })()", expected)
    assert_equal expected, value, "permalink should match room/@id"
  end

  def test_uploading_an_image_attachment
    png = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
    dir = Parity::Snap.dir_for(self)
    FileUtils.mkdir_p(dir)
    file = File.join(dir, "parity-pixel.png")
    File.binwrite(file, png)
    find("input[type='file']", visible: :all).attach_file(file)
    # Picking a file only queues it in the composer; Send submits the upload.
    find("button[name='send']").click
    # Image attachments render an img preview, not the filename.
    assert_selector ".message[data-message-id] img.message__attachment", wait: 20
    settled_snap("uploaded-image", mask_times: true)
  end
end

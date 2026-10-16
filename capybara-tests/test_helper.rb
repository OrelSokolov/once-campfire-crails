# frozen_string_literal: true

require "bundler/setup"
require "capybara/dsl"
require "capybara/cuprite"
require "minitest/autorun"
require_relative "harness/labels"
require_relative "harness/boot"
require_relative "harness/states"
require_relative "harness/snap"
require_relative "harness/normalize"

require "fileutils"
require_relative "harness/labels"

# View transitions animate navigations; snapshots would catch them mid-flight.
# Both parity targets run with them stubbed out. Ferrum extensions are file
# paths, so materialize the script under the suite's tmp dir.
PARITY_NO_VT_JS = File.join(Parity::RUN_DIR, "no-view-transitions.js")
FileUtils.mkdir_p(Parity::RUN_DIR)
File.write(PARITY_NO_VT_JS, <<~JS)
  Document.prototype.startViewTransition = function (callback) {
    try { callback && callback() } catch (error) {}
    return { finished: Promise.resolve(), ready: Promise.resolve(),
             updateCallbackDone: Promise.resolve(), skipTransition() {} }
  }
JS

Capybara.register_driver :parity_cuprite do |app|
  Capybara::Cuprite::Driver.new(app,
    browser_path: Parity::Boot::CHROME,
    headless: true,
    window_size: [1400, 1400],
    process_timeout: 30,
    timeout: 20,
    # Page-level uncaught errors (e.g. aborted prefetch fetches) are app
    # noise; the suite asserts on the DOM instead.
    js_errors: false,
    extensions: [PARITY_NO_VT_JS],
    env: { "TZ" => "UTC" })
end

Capybara.default_driver = :parity_cuprite
Capybara.run_server = false
Capybara.app_host = ENV["PARITY_BASE_URL"]
Capybara.default_max_wait_time = 10

module Parity
  def self.boot!
    server = Boot.boot(TARGET)
    self.base_url = server.base_url
    Capybara.app_host = server.base_url
    puts "[parity] #{TARGET} booted at #{server.base_url}"
    server
  end

  def self.base_url
    @base_url
  end

  def self.base_url=(value)
    @base_url = value
  end

  def self.server_alive?
    uri = URI("#{base_url}/up")
    Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
      http.get(uri.path).is_a?(Net::HTTPSuccess)
    end
  rescue StandardError
    false
  end

  # crails currently segfaults (signal 11 in bin/app) somewhere during the
  # multi-session live tests; without handling, every test after the crash
  # fails with ECONNREFUSED and writes no artifacts. Relaunch the server on
  # the same data dir so the run completes — the crash itself stays a parity
  # finding, reported via the missing-artifact diff for the test that died.
  def self.ensure_server!
    return if $parity_server.nil? || server_alive?

    warn "[parity] #{TARGET} died mid-run — rebooting on the same data dir"
    $parity_server = Boot.restart($parity_server)
    self.base_url = $parity_server.base_url
    Capybara.app_host = base_url
  end
end

$parity_server =
  if ENV["PARITY_BASE_URL"]
    Parity.base_url = ENV["PARITY_BASE_URL"]
    Capybara.app_host = ENV["PARITY_BASE_URL"]
    nil # external server, nothing to own
  else
    Parity.boot!
  end

# Shared app-level helpers, in the spirit of upstream test/test_helpers.
module ParityHelpers
  def sign_in_as!(role = :david)
    Parity::States.sign_in_as(page, role, Parity.base_url)
  end

  def sign_in_through_ui!(email)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: Parity::PASSWORD
    find("button[name='log_in']").click
    assert_current_path(%r{/rooms/\d+\z}, wait: 15)
  end

  def open_room!(room_id)
    visit "/rooms/#{room_id}"
    assert_selector(".message-area, .messages, #message-area", wait: 10)
    assert_selector("lexxy-editor#message_body", wait: 10)
    # The sidebar is a lazy turbo-frame; wait for it so snapshots are stable,
    # including the read-marker JS settling on the current room. Re-check
    # after a beat — the sidebar can reload with stale server state. The
    # unread class may not exist on all targets; the href wait is the common
    # denominator.
    assert_selector("#user_sidebar a[href='/rooms/#{room_id}']", wait: 10)
    sleep 0.4
    assert_selector("#user_sidebar a[href='/rooms/#{room_id}']:not(.unread)", wait: 5)
  end

  def cookie_header
    page.driver.browser.cookies.all.map { |name, cookie| "#{name}=#{cookie.value}" }.join("; ")
  end

  def message_with_text(text)
    find(".message[data-message-id]", text:, match: :first)
  end

  def message_with_text!(text)
    assert_selector(".message[data-message-id]", text:)
    message_with_text(text)
  end

  def send_message!(text)
    set_editor_value("<div>#{text}</div>")
    find("button[name='send']").click
    message_with_text!(text)
  end

  def set_editor_value(html)
    # Cuprite's evaluate_script wraps the script as `return <expr>`; use
    # execute_script whose wrapper is a plain function body (statements OK,
    # args via arguments[0]).
    page.execute_script(<<~JS, html)
      const editor = document.querySelector('lexxy-editor#message_body')
      editor.value = arguments[0]
      editor.dispatchEvent(new Event("input", { bubbles: true }))
    JS
  end

  def settled_snap(name, mask_times: false)
    Parity::Snap.snap(page, self, name, mask_times:)
  end

  def snap_element(name, selector, mask_times: false)
    Parity::Snap.snap_element(page, self, name, selector, mask_times:)
  end
end

class ParityTest < Minitest::Test
  include Capybara::DSL
  include ParityHelpers

  # before_setup (not setup) so test classes overriding setup keep the check.
  def before_setup
    super
    Parity.ensure_server!
  end

  def teardown
    Capybara.reset_sessions!
  end
end

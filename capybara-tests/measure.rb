# frozen_string_literal: true

# Boots rails + crails side by side, replicates the composer-post flow and
# dumps raw message HTML + geometry from each target for comparison.

ENV["TARGET"] = "crails"
ENV["PARITY_BASE_URL"] = "http://127.0.0.1:1" # skip auto-boot in test_helper
# Scrub the parent shell's rvm/bundler environment so launched targets
# resolve their own bundles.
%w[GEM_HOME GEM_PATH RUBY_VERSION MY_RUBY_HOME IRBRC RUBYOPT RUBYLIB].each { |k| ENV.delete(k) }
ENV.delete_if { |key, _| key.start_with?("BUNDLE_", "BUNDLER_") }
require_relative "test_helper"

# The parent shell's rvm setup leaks into spawned targets (4.0.4 rubygems ends
# up loading 3.4.5's bundler). Launch children with a hard-scrubbed env.
module Parity
  module Boot
    def self.launch(cmd, args, cwd:, env:, log_file:)
      File.open(log_file, "a") do |io|
        io.puts "# parity launch #{Time.now.utc.iso8601}: #{cmd} #{args.join(' ')}"
      end
      pid = Process.spawn(env.merge("HOME" => ENV.fetch("HOME", Dir.home), "PATH" => ENV.fetch("PATH")), cmd, *args,
        chdir: cwd, out: [log_file, "a"], err: [log_file, "a"],
        unsetenv_others: true)
      ProcessHandle.new(pid, log_file)
    end
  end
end

MEASURE_JS = <<~JS
  (() => {
    const num = (r) => r ? [r.x, r.y, r.width, r.height].map((v) => Math.round(v * 10) / 10) : null;
    return JSON.stringify(Array.from(document.querySelectorAll(".message[data-message-id], #system_welcome")).map((m) => {
      const sep = m.querySelector(":scope > .message__day-separator, :scope > h2.message__day-separator");
      return {
        id: m.id,
        cls: m.className,
        rect: num(m.getBoundingClientRect()),
        sepRect: num(sep && sep.getBoundingClientRect()),
        avatarRect: num(m.querySelector(".message__avatar") && m.querySelector(".message__avatar").getBoundingClientRect()),
        bodyRect: num(m.querySelector(".message__body-content") && m.querySelector(".message__body-content").getBoundingClientRect()),
        lexxyRect: num(m.querySelector(".lexxy-content") && m.querySelector(".lexxy-content").getBoundingClientRect()),
        metaRect: num(m.querySelector(".message__meta") && m.querySelector(".message__meta").getBoundingClientRect()),
        headingRect: num(m.querySelector(".message__heading") && m.querySelector(".message__heading").getBoundingClientRect()),
        times: Array.from(m.querySelectorAll("time")).map((t) => ({
          dt: t.getAttribute("datetime"),
          text: t.textContent,
          rect: num(t.getBoundingClientRect()),
        })),
      };
    }));
  })()
JS

def dump_for(target, server, out_path)
  Capybara.reset_sessions!
  Capybara.app_host = server.base_url
  Parity.base_url = server.base_url
  page = Capybara.current_session
  Parity::States.sign_in_as(page, :david, server.base_url)
  visit "/rooms/#{Parity::ROOMS.fetch(:hq)}"
  find("lexxy-editor#message_body", wait: 15)
  sleep 1

  # Post a message through the composer, exactly like the live tests do.
  page.execute_script("const editor = document.querySelector('lexxy-editor#message_body'); editor.value = '<div>Live: boost me</div>'; editor.dispatchEvent(new Event('input', { bubbles: true }));")
  find("button[name='send']").click
  boost_msg = find(".message[data-message-id]", text: "Live: boost me", wait: 15)

  # A second user (Jason) boosts it over HTTP — David's page receives the
  # boost through the cable stream, same as test_boosts_propagate.
  page.execute_script("sessionStorage.setItem('who', 'david')")
  message_id = boost_msg["data-message-id"]
  boost_as_jason(server, message_id)
  find(".boost-item", wait: 30)
  sleep 1
  puts "[#{target}] boost arrived"

  # Post and edit a message through the lazy edit turbo-frame, like
  # test_edits_propagate (authoring session re-renders through the frame).
  page.execute_script("const editor = document.querySelector('lexxy-editor#message_body'); editor.value = '<div>Live: edit me</div>'; editor.dispatchEvent(new Event('input', { bubbles: true }));")
  find("button[name='send']").click
  edit_msg = find(".message[data-message-id]", text: "Live: edit me", wait: 15)
  edit_msg.find("summary").click
  edit_msg.find(".message__edit-btn").click
  editor = edit_msg.find("[aria-label='Edit message']", match: :first)
  editor.click
  page.execute_script(<<~JS)
    const editor = document.querySelector("[aria-label='Edit message']")
    editor.value = "Live: edited live"
    editor.dispatchEvent(new Event("input", { bubbles: true }))
  JS
  edit_msg.find("button", text: /Save/).click
  edited = find(".message[data-message-id]", text: "Live: edited live", wait: 15)
  edited.find("turbo-frame[id^='edit_message_'][complete]", wait: 10)
  sleep 3 # let every stream replacement settle

  File.write(out_path, page.evaluate_script(MEASURE_JS))
  # Full-page screenshot, same pipeline as the parity suite, plus raw HTML of
  # every message for a direct un-normalized comparison.
  Capybara.using_session("booster") { Capybara.reset_sessions! } rescue nil
  File.write("#{out_path}.messages.html", page.evaluate_script(
    "Array.from(document.querySelectorAll('.message[data-message-id]')).map((m) => m.outerHTML).join('\\n<!--MSG-SPLIT-->\\n')"
  ))
  page.save_screenshot("#{out_path}.png", full: true)
  puts "[#{target}] dumped to #{out_path}"
rescue StandardError => e
  warn "[#{target}] FAILED: #{e.class}: #{e.message}"
  File.write("#{out_path}.err.html", page.html) rescue nil
  warn e.backtrace.first(3)
end

def boost_as_jason(server, message_id)
  jar = Parity::States.send(:login, Parity::EMAILS.fetch(:jason), server.base_url)
  uri = URI("#{server.base_url}/rooms/#{Parity::ROOMS.fetch(:hq)}")
  cookie = jar.map { |name, value| "#{name}=#{value}" }.join("; ")
  Net::HTTP.start(uri.host, uri.port) do |http|
    page_response = http.get(uri.path, "cookie" => cookie)
    csrf = page_response.body[/name="csrf-token" content="([^"]+)"/, 1]
    request = Net::HTTP::Post.new("/messages/#{message_id}/boosts")
    request.set_form_data({ "boost[content]" => "👍", "authenticity_token" => csrf.to_s })
    request["cookie"] = cookie
    response = http.request(request)
    raise "boost failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
  end
end

include Capybara::DSL

out_dir = File.join(Parity::SUITE_ROOT, "tmp", "measure")
FileUtils.mkdir_p(out_dir)

rails = crails = nil
begin
  crails = Parity::Boot.crails(port: Parity::Boot.free_port)
  rails = Parity::Boot.rails(port: Parity::Boot.free_port, redis_port: Parity::Boot.free_port)
  dump_for("rails", rails, File.join(out_dir, "rails.json"))
  dump_for("crails", crails, File.join(out_dir, "crails.json"))
ensure
  rails&.teardown
  crails&.teardown
end

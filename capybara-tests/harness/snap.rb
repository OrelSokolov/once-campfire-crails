# frozen_string_literal: true

require "fileutils"
require_relative "labels"
require_relative "normalize"

module Parity
  # Deterministic page snapshots: full-page screenshot + normalized HTML under
  # artifacts/<target>/<test-file>/<test>/<name>.{png,html}
  module Snap
    QUIET_CSS = <<~CSS
      *, *::before, *::after {
        animation: none !important;
        transition: none !important;
        caret-color: transparent !important;
        scroll-behavior: auto !important;
      }
    CSS

    SETTLED_JS = <<~JS
      (() => new Promise((resolve) => {
        const timeout = setTimeout(resolve, 2000);
        const framesDone = () => Array.from(document.querySelectorAll("turbo-frame[src]")).every((frame) => frame.hasAttribute("complete"));
        const animsDone = () => document.getAnimations({ subtree: true }).length === 0;
        const check = () => {
          if (framesDone() && animsDone()) {
            requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(timeout); resolve(); }));
          } else {
            setTimeout(check, 50);
          }
        };
        Promise.all([
          document.fonts.ready,
          ...Array.from(document.images).map((image) =>
            image.complete ? Promise.resolve() :
              new Promise((done) => {
                image.addEventListener("load", done, { once: true });
                image.addEventListener("error", done, { once: true });
              })),
        ]).then(() => check(), () => check());
      }))()
    JS

    # Presentation state that can never match across runs: each target boots
    # on a random free port that leaks into rendered text and input values
    # (the invite-link banner), and which element holds focus when the shot
    # lands is a race (the live tests juggle two tabs in one browser).
    # Pin both to a canonical form before capture so PNGs compare across runs.
    PIN_JS = <<~JS
      (() => {
        if (document.activeElement && document.activeElement !== document.body) {
          document.activeElement.blur()
        }
        const origin = location.origin
        const pinned = "http://127.0.0.1:__PORT__"
        const texts = []
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
        while (walker.nextNode()) texts.push(walker.currentNode)
        for (const node of texts) {
          if (node.nodeValue.includes(origin)) node.nodeValue = node.nodeValue.split(origin).join(pinned)
        }
        for (const field of document.querySelectorAll("input[type=text], textarea")) {
          if (field.value.includes(origin)) field.value = field.value.split(origin).join(pinned)
        }
      })()
    JS

    module_function

    def pin_volatile(page)
      page.execute_script(PIN_JS)
    end

    def dir_for(test)
      file = underscore(test.class.name)
      File.join(Parity::ARTIFACTS, file.sub(/_test\z/, ""), underscore(test.name))
    end

    def snap(page, test, name, mask_times: false)
      dir = dir_for(test)
      FileUtils.mkdir_p(dir)
      html = stable_html(page) { page.evaluate_script("document.documentElement.outerHTML") }
      pin_volatile(page)
      hide_volatile(page, ["time"]) if mask_times
      page.save_screenshot(File.join(dir, "#{name}.png"), full: true)
      File.write(File.join(dir, "#{name}.html"), html)
    ensure
      restore_volatile(page) if mask_times
    end

    def snap_element(page, test, name, selector, mask_times: false)
      dir = dir_for(test)
      FileUtils.mkdir_p(dir)
      html = stable_html(page) { page.evaluate_script("document.querySelector(#{selector.to_json}).outerHTML") }
      pin_volatile(page)
      hide_volatile(page, ["time"]) if mask_times
      page.save_screenshot(File.join(dir, "#{name}.png"), full: true)
      File.write(File.join(dir, "#{name}.html"), html)
    ensure
      restore_volatile(page) if mask_times
    end

    # Async DOM mutations (cable streams, lazy turbo-frames, sidebar reloads)
    # race a single capture. Require two consecutive identical normalized
    # captures before trusting the page as snapshot-stable.
    def stable_html(page, attempts: 6)
      normalized = nil
      attempts.times do
        pin_volatile(page)
        quiet(page)
        settled(page)
        candidate = Parity::Normalize.html(yield, Parity.base_url)
        return candidate if candidate == normalized

        normalized = candidate
        sleep 0.4
      end
      normalized
    end

    def quiet(page)
      page.execute_script(<<~JS)
        if (!document.getElementById("parity-quiet")) {
          const style = document.createElement("style");
          style.id = "parity-quiet";
          style.textContent = #{QUIET_CSS.to_json};
          document.head.appendChild(style);
        }
      JS
      # Toast flashes remove themselves on animationend, which the CSS above
      # disables — they would linger nondeterministically. Drop them instead.
      page.execute_script("document.querySelectorAll('.flash').forEach((el) => el.remove())")
    end

    def hide_volatile(page, selectors)
      page.execute_script("window.__parityHidden = []", *[]) rescue nil
      page.execute_script(<<~JS, selectors.to_json)
        window.__parityHidden = [];
        for (const selector of JSON.parse(arguments[0])) {
          for (const element of document.querySelectorAll(selector)) {
            if (element.style.visibility !== "hidden") {
              window.__parityHidden.push(element);
              element.style.visibility = "hidden";
            }
          }
        }
      JS
    end

    def restore_volatile(page)
      page.execute_script(<<~JS)
        (window.__parityHidden || []).forEach((element) => element.style.visibility = "");
        window.__parityHidden = [];
      JS
    rescue Capybara::CupriteError
      nil
    end

    def settled(page)
      begin
        page.driver.browser.network.wait_for_idle(timeout: 3)
      rescue StandardError
        nil
      end
      page.execute_script(SETTLED_JS)
    end

    def underscore(name)
      name.to_s.gsub("::", "/").gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.gsub(/[^\w-]+/, "-")
    end
  end
end

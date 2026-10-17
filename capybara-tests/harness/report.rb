# frozen_string_literal: true

require "cgi"

module Parity
  # 1:1 gallery report: every PNG pair (baseline | target) laid out flex 50/50,
  # scroll top-to-bottom, filename pinned to the top of each pair. Failed pairs
  # come first. The old summary table stays below in a collapsed <details>.
  module Report
    module_function

    def esc(text)
      CGI.escapeHTML(text.to_s)
    end

    # Severity coloring for pixel-diff percentages (mirrors Parity::Compare):
    # <1% ok, >=1% yellow, >=5% red, >=10% bold inverted red.
    def px_severity(pct)
      return :worst if pct >= 10
      return :bad if pct >= 5
      return :warn if pct >= 1
      :ok
    end

    def render(summary:, results:, baseline:, target:, suite: nil)
      # Report lives in artifacts/compare/, images in artifacts/<target>/ —
      # relative srcs so the page works from any file:// location.
      base = "../#{baseline}"
      targ = "../#{target}"
      pngs = results.select { |r| r[:kind] == "png" }.sort_by { |r| [r[:pass] ? 1 : 0, r[:rel]] }
      shots = pngs.map { |item| shot(item, base, targ, baseline, target, suite ? File.join(suite, "artifacts", "compare") : nil) }.join("\n")
      table = summary_table(results:, base:, targ:, baseline:, target:)
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><title>1:1 #{baseline} vs #{target}</title>
        <style>
          body{font:14px -apple-system,system-ui,sans-serif;margin:0;background:#eee}
          header{position:sticky;top:0;z-index:20;background:#fff;border-bottom:1px solid #ccc;padding:8px 16px;display:flex;gap:16px;align-items:center;flex-wrap:wrap}
          header h1{font-size:16px;margin:0}
          header label{cursor:pointer;user-select:none}
          body.only-pass .shot.fail{display:none}
          body.only-fail .shot.pass{display:none}
          .shot{background:#fff;margin:16px 0}
          .shot.fail h3{background:#fdd}
          .shot h3{position:sticky;top:37px;z-index:10;margin:0;padding:6px 16px;font:600 13px ui-monospace,monospace;border-bottom:1px solid #ddd;background:#fff}
          .shot h3 .detail{font-weight:400;color:#555}
          .shot h3 .detail.warn{color:#960;background:#ffd700}
          .shot h3 .detail.bad{color:#fff;background:#f30}
          .shot h3 .detail.worst{color:#fff;background:#900}
          .pair{display:flex}
          .pair>figure{flex:1 1 50%;min-width:0;margin:0}
          .pair>figure+figure{border-left:1px solid #ccc}
          .pair figcaption{padding:4px 8px;font:600 12px ui-monospace,monospace;background:#fafafa;border-bottom:1px solid #eee}
          .pair a{display:block}
          .pair img{display:block;width:100%;height:auto}
          details.summary{margin:24px 16px}
          table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 10px;text-align:left}tr.fail td{background:#fdd}tr.pass td{background:#dfd}code{font-size:12px}
          tr td.warn{background:#ffd700}tr td.bad{background:#f30;color:#fff}tr td.worst{background:#900;color:#fff;font-weight:700}
        </style>
        </head><body>
        <header>
          <h1>1:1 #{esc baseline} ↔ #{esc target}</h1>
          <span>png #{summary[:png_passed]}/#{summary[:png_total]} · html #{summary[:html_passed]}/#{summary[:html_total]} · missing #{summary[:missing]}</span>
          <label><input type="radio" name="filter" onchange="document.body.className=''" checked>все</label>
          <label><input type="radio" name="filter" onchange="document.body.className='only-fail'">провалы</label>
          <label><input type="radio" name="filter" onchange="document.body.className='only-pass'">прошедшие</label>
        </header>
        #{shots}
        <details class="summary"><summary>Таблица результатов (#{results.size})</summary>
        #{table}
        </details>
        </body></html>
      HTML
    end

    # One screenshot pair: pinned filename header + baseline/target side by side.
    def shot(item, base, targ, baseline, target, compare_dir = nil)
      rel = item[:rel]
      status = item[:pass] ? "pass" : "fail"
      detail = if item[:missing]
                 "missing in #{item[:missing]}"
               elsif item[:ratio]
                 format("· %.3f%% px (%d/%d)", item[:ratio] * 100, item[:diff_pixels] || 0, item[:total] || 0)
               elsif item[:error]
                 item[:error].to_s
               else
                 ""
               end
      detail_cls = item[:ratio] ? px_severity(item[:ratio] * 100) : nil
      detail_cls = nil if detail_cls == :ok || !item[:ratio]
      detail_span = detail.empty? ? "" : %( <span class="detail#{detail_cls ? " #{detail_cls}" : ""}">#{esc detail}</span>)
      left = item[:missing] == "baseline" ? %(<figure><figcaption>#{esc baseline}</figcaption></figure>) : side(base, rel, baseline)
      right = item[:missing] == "target" ? %(<figure><figcaption>#{esc target}</figcaption></figure>) : side(targ, rel, target)
      diff = ""
      if compare_dir && item[:kind] == "png" && !item[:pass] && !item[:missing]
        diff_rel = rel.sub(".png", ".diff.png")
        diff = %( <a class="diff" href="#{esc diff_rel}">diff</a>) if File.exist?(File.join(compare_dir, diff_rel))
      end
      %(<section class="shot #{status}"><h3>#{esc rel} #{diff}#{detail_span}</h3>\n<div class="pair">#{left}#{right}</div></section>)
    end

    def side(prefix, rel, label)
      %(<figure><figcaption>#{esc label}</figcaption><a href="#{esc "#{prefix}/#{rel}"}"><img src="#{esc "#{prefix}/#{rel}"}" loading="lazy" alt=""></a></figure>)
    end

    def summary_table(results:, base:, targ:, baseline:, target:)
      rows = results.map do |item|
        status = item[:pass] ? "pass" : "fail"
        detail = if item[:missing]
                   "missing in #{item[:missing]}"
                 elsif item[:ratio]
                   format("%d/%d px (%.3f%%)", item[:diff_pixels] || 0, item[:total] || 0, item[:ratio] * 100)
                 elsif item[:diff_lines]
                   "#{item[:diff_lines]} diff lines"
                 elsif item[:error]
                   item[:error].to_s
                 else
                   ""
                 end
        pct = item[:ratio] ? item[:ratio] * 100 : nil
        severity = pct ? px_severity(pct) : nil
        detail_cls = severity && severity != :ok ? %( class="#{severity}") : ""
        diff_link = item[:kind] == "png" && !item[:pass] && !item[:missing] ? %(<a href="#{esc item[:rel].sub('.png', '.diff.png')}">diff</a>) : ""
        pair = %(<a href="#{esc "#{base}/#{item[:rel]}"}">#{esc baseline}</a> · <a href="#{esc "#{targ}/#{item[:rel]}"}">#{esc target}</a>)
        %(<tr class="#{status}"><td><code>#{esc item[:rel]}</code></td><td>#{esc item[:kind]}</td><td>#{status}</td><td#{detail_cls}>#{esc detail}</td><td>#{diff_link}</td><td>#{pair}</td></tr>)
      end.join("\n")
      <<~HTML
        <table><tr><th>snapshot</th><th>kind</th><th>status</th><th>detail</th><th>diff</th><th>pair</th></tr>
        #{rows}
        </table>
      HTML
    end
  end
end

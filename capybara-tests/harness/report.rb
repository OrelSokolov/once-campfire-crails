# frozen_string_literal: true

module Parity
  module Report
    module_function

    def render(summary:, results:, baseline:, target:)
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
        diff_link = item[:kind] == "png" && !item[:pass] ? %(<a href="#{item[:rel].sub('.png', '.diff.png')}">diff</a>) : ""
        pair = %(<a href="../#{baseline}/#{item[:rel]}">#{baseline}</a> · <a href="../#{target}/#{item[:rel]}">#{target}</a>)
        %(<tr class="#{status}"><td><code>#{item[:rel]}</code></td><td>#{item[:kind]}</td><td>#{status}</td><td>#{detail}</td><td>#{diff_link}</td><td>#{pair}</td></tr>)
      end.join("\n")
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><title>parity #{baseline} vs #{target}</title>
        <style>body{font:14px -apple-system,system-ui,sans-serif;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 10px;text-align:left}tr.fail td{background:#fdd}tr.pass td{background:#dfd}code{font-size:12px}</style>
        </head><body>
        <h1>Browser parity: #{baseline} vs #{target}</h1>
        <p>png #{summary[:png_passed]}/#{summary[:png_total]} · html #{summary[:html_passed]}/#{summary[:html_total]} · missing #{summary[:missing]} · max ratio #{summary[:max_ratio]}</p>
        <table><tr><th>snapshot</th><th>kind</th><th>status</th><th>detail</th><th>diff</th><th>pair</th></tr>
        #{rows}
        </table></body></html>
      HTML
    end
  end
end

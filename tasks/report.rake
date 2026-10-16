# frozen_string_literal: true

# ————— report: summary comparison table from reports —————

def bold(s) = $stdout.tty? ? "\e[1m#{s}\e[0m" : s

def thousands(n) = n.round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse

desc "Comparison table (routes × apps, median RPS) from benchmarks/*/summary.json"
task :report do
  require "terminal-table"

  reports = Dir[File.join(RESULTS_DIR, "*", "summary.json")].sort
  abort "No reports in benchmarks/ — run `rake benchmark` first." if reports.empty?

  # app → { medians: route → median_rps, rev:, dir: }; a later report
  # (directory name is a UTC timestamp) overwrites an earlier one for the same app.
  data_by_app = {}
  skipped = []
  reports.each do |path|
    dir = File.basename(File.dirname(path))
    data = JSON.parse(File.read(path))
    next skipped << dir unless data.dig("metadata", "complete")

    revs = data.dig("metadata", "source_revisions") || {}
    data.fetch("results").each do |app, summary|
      medians = summary.filter_map { |route, v| [route, v["median_rps"]] if v.is_a?(Hash) && v["median_rps"] }.to_h
      # Reports predating the compare.rb patch kept only 5 routes in summary —
      # pick up the missing ones with the median from per-round files <app>-N.json.
      measured = (data.dig("metadata", "routes") || "").split(",")
      missing = measured - medians.keys
      unless missing.empty?
        round_rows = Dir[File.join(dir, "#{app}-*.json")].sort.map { |f| JSON.parse(File.read(f)) }
        missing.each do |route|
          samples = round_rows.filter_map { |row|
            row["http"]&.find { |it| it["route"] == route && it["conc"] == 16 }&.fetch("rps")
          }
          medians[route] = samples.sort[samples.size / 2] unless samples.empty?
        end
      end
      data_by_app[app] = { medians: medians, rev: revs.dig(app, "head").to_s[0, 7], dir: dir }
    end
  end
  abort "All reports are incomplete (complete: false) — no run reached the summary." if data_by_app.empty?

  apps   = APP_ORDER.select { |a| data_by_app.key?(a) } + (data_by_app.keys - APP_ORDER)
  routes = ROUTE_ORDER + (data_by_app.values.flat_map { |d| d[:medians].keys } - ROUTE_ORDER)

  puts
  puts "Median RPS, 3 rounds × 16 clients (bold — best per route):"
  table = Terminal::Table.new do |t|
    t.headings = ["Route", *apps]
    t.align_column(0, :left)
    apps.each_index { |i| t.align_column(i + 1, :right) }
    routes.uniq.each do |route|
      medians = apps.map { |a| data_by_app[a][:medians][route] }
      best = medians.compact.max
      t.add_row([ROUTE_LABEL.fetch(route, route), *medians.map { |m|
        m.nil? ? "—" : (m == best ? bold(thousands(m)) : thousands(m))
      }])
    end
    t.add_row(["Revision", *apps.map { |a| data_by_app[a][:rev] }.map { |r| r.nil? || r.empty? ? "—" : r }])
  end
  puts table
  puts
  puts <<~NOTE
    post_message is not equivalent across apps (durability). Rust and Go run
    push/webhook notification jobs in in-process queues with no persistence at
    all, and the POST response does not wait for them:

      rust: "Queued work is lost if the process crashes, which the plan accepts" —
            https://github.com/basecamp/once-campfire-rust/blob/6dae2fd/crates/campfire/src/jobs.rs
      go:   dropped when the channel overflows, lost on a crash —
            https://github.com/basecamp/once-campfire-go/blob/c4ab53d/internal/jobs/jobs.go

    Express and CRails persist every notification job into the leased-SQLite
    queue before responding (express: src/jobs.js enqueueMany; crails:
    app/jobs/job_queue.cr) — that guarantee costs RPS on post_message and
    explains the gap in the row above.
  NOTE
  puts
  apps.each { |a| puts "  #{a}: #{data_by_app[a][:dir]} @ #{data_by_app[a][:rev]}" }
  puts "  Skipped incomplete runs: #{skipped.join(", ")}" unless skipped.empty?
  puts
end

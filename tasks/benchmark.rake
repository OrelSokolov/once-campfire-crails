# frozen_string_literal: true

# ————— verify / benchmark / run —————

def run_henchmark(apps, extra)
  server, client = cpu_sets
  step "CPU: server=#{server} client=#{client}"
  sh!(File.join(HARNESS, "bin", "benchmark"), "--apps", apps.join(","),
      "--cpus", server, "--client-cpus", client,
      "--rounds", ENV.fetch("BENCH_ROUNDS", "3"),
      "--duration", ENV.fetch("BENCH_DURATION", "8"), *extra, env: harness_env)
end

def save_results(label)
  return if dry_run?
  results = File.join(HARNESS, "tmp", "bench", "results")
  latest = Dir[File.join(results, "*")].select { |d| File.directory?(d) }.max_by { |d| File.mtime(d) }
  return puts "(no results to copy)" unless latest
  dest = File.join(RESULTS_DIR, "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{label}")
  FileUtils.mkdir_p(RESULTS_DIR)
  FileUtils.cp_r(latest, dest)
  step "Results: #{dest}"
end

desc "Preflight verification of images: contracts without load (verify[c] — selectively)"
task :verify, [:app] do |_t, args|
  abort "Verification requires Linux (docker --network host + taskset)." unless linux?
  apps = each_app(args[:app])
  apps.each { |a| abort "Image #{IMAGE[a]} not built: rake build[#{a}]" unless image_exists?(IMAGE[a]) }
  Rake::Task["harness"].invoke # idempotent: fetches/checks the harness before the run
  run_henchmark(apps, ["--preflight"])
end

desc "Formal benchmark (benchmark[c] — a single app; without an argument — all apps, one run)"
task :benchmark, [:app] do |_t, args|
  abort "Benchmarking requires Linux (docker --network host + taskset)." unless linux?
  apps = each_app(args[:app])
  apps.each { |a| abort "Image #{IMAGE[a]} not built: rake build[#{a}]" unless image_exists?(IMAGE[a]) }
  Rake::Task["harness"].invoke # idempotent: fetches/checks the harness before the run
  run_henchmark(apps, [])
  save_results(apps.join("_"))
end

desc "Full cycle: deps → download → build (crails last) → harness → verify → benchmark"
task :run do
  %w[deps download build harness verify benchmark].each { |t| Rake::Task[t].invoke }
end

task default: :run

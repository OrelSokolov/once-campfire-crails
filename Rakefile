# frozen_string_literal: true

# Full cycle of the comparative ONCE Campfire benchmark on this machine:
# the official basecamp/once-campfire-verification harness.
#
#   rake deps                  # host dependencies (Linux apt / macOS brew)
#   rake download              # clone all competitor repositories at pinned revisions (submodules recursively)
#   rake download[c,go]        # ...selectively
#   rake build                 # build docker images of all applications
#   rake build[rust]           # ...selectively
#   rake harness               # clone the harness, apply the crails patch,
#                              # bin/check, build loadgen, build the seed database (bin/seed)
#   rake verify                # preflight verification of each image (contracts, no load)
#   rake verify[c]
#   rake benchmark             # formal run: all applications, 3 rounds, interleaved
#   rake benchmark[c]          # ...a single application
#   rake report                # summary comparison table (routes × apps) from benchmarks/
#   rake run                   # EVERYTHING sequentially: deps→download→build→harness→verify→benchmark
#
# Results: benchmarks/<UTC-timestamp>-<apps>/ (summary.json + raw samples).
#
# Environment variables:
#   BENCH_SERVER_CPUS  server cpuset     (default: autodetect 2 SMT cores, else 0,1,8,9)
#   BENCH_CLIENT_CPUS  generator cpuset  (default: 4 separate cores, else 4-7)
#   BENCH_ROUNDS       rounds (default 3), BENCH_DURATION seconds (default 8)
#   REBUILD=1          rebuild existing images
#   DRY_RUN=1          print commands without executing them
#
# Benchmarking and verification require Linux (docker --network host, taskset in the harness);
# on macOS only deps/download/build are available.

require "bundler/setup" # Gemfile gems (terminal-table for report) — vendor/bundle

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

# Bash glob trap: `rake benchmark[crails]` gets expanded by the shell into
# the existing benchmarks/ directory (the character class [crails] contains 's';
# same for rails/express), and rake silently treats it as an existing file task.
# Restore the intent and hint at the correct syntax.
if (idx = ARGV.index("benchmarks"))
  ARGV[idx] = "benchmark"
  puts "NOTE: the argument expanded to the benchmarks/ directory — running benchmark without a filter."
  puts "For a single application use `rake benchmark:crails` or `rake 'benchmark[crails]'`."
end

# ————— Configuration: application → repository at a pin —————
# Pins are revisions from the README table (upstream as of 2026-10-09); rails is main
# at measurement time (vanilla 90b3300 does not pass the current harness,
# see REPORT.md). CRails is this repository and is added LAST:
# its launch method changes, so we keep it at the tail of the queue.
HARNESS_REPO  = "https://github.com/basecamp/once-campfire-verification.git"
HARNESS_REV   = "ec02debb3e44f40b8778a6a42db3c4515b2f9eaf"

APPS = {
  "rails"   => { repo: "https://github.com/basecamp/once-campfire.git",         rev: "edbc779f4dfc9b26c36310881711ddc976a9dfc8" },
  "express" => { repo: "https://github.com/basecamp/once-campfire-express.git", rev: "bb70a7d478160c016393d981e3538987247d3b3d" },
  "go"      => { repo: "https://github.com/basecamp/once-campfire-go.git",      rev: "c4ab53d00b0a19a55962e03d18057ca6c3da9437" },
  "rust"    => { repo: "https://github.com/basecamp/once-campfire-rust.git",    rev: "6dae2fd3c1a2dce61ca11beb731bcce2b42b67ad" },
  "c"       => { repo: "https://github.com/basecamp/once-campfire-c.git",       rev: "873a51f523de5a0cc235884e5725cfb5521d2027" },
  "elixir"  => { repo: "https://github.com/basecamp/once-campfire-elixir.git",  rev: "58964cf8a8788b2a20c7bde16dae65b025812593" },
}.freeze
CRAILS_APP = "crails"
APP_ORDER  = APPS.keys + [CRAILS_APP] # crails strictly last

REPO_ROOT     = File.expand_path(__dir__)
WORKSPACE     = File.join(REPO_ROOT, "bench-workspace")
HARNESS       = File.join(WORKSPACE, "once-campfire-verification")
HARNESS_PATCH = File.join(REPO_ROOT, "benchmark", "harness-crails.patch")
RESULTS_DIR   = File.join(REPO_ROOT, "benchmarks")

# Image names — defaults of bench/compare.rb (RAILS_IMAGE etc. are not needed).
IMAGE = {
  "rails" => "once-campfire:app", "express" => "once-campfire-express:app",
  "go" => "once-campfire-go:app", "rust" => "campfire-rust:app",
  "c" => "once-campfire-c:app", "elixir" => "campfire-elixir:app",
  CRAILS_APP => "once-campfire-crails:app",
}.freeze

# Route order in harness reports (README tables) and their display labels.
ROUTE_ORDER = %w[room_show messages_page sidebar search avatar static_css up post_message].freeze
ROUTE_LABEL = { "up" => "/up" }.freeze

# ————— Utilities —————

def darwin?  = RbConfig::CONFIG["host_os"].include?("darwin")
def linux?   = RbConfig::CONFIG["host_os"].include?("linux")
def dry_run? = ENV["DRY_RUN"] == "1"

# Step banners: bold blue in a TTY, "==>" prefix always, so progress lines
# stand out in build/download logs.
def step(msg)
  puts $stdout.tty? ? "\e[1;34m==> #{msg}\e[0m" : "==> #{msg}"
end

def sh!(*cmd, env: {}, chdir: nil)
  puts "+ #{env.reject { |_k, v| v.nil? }.map { |k, v| "#{k}=#{v}" }.join(" ")} #{cmd.join(" ")}".strip
  return if dry_run?
  ok = chdir ? system(env, *cmd, chdir: chdir) : system(env, *cmd)
  abort "FAILED: #{cmd.join(" ")}" unless ok
end

# Like sh!, but false instead of abort — for retries.
def sh?(*cmd, env: {}, chdir: nil)
  puts "+ #{cmd.join(" ")}"
  return true if dry_run?
  chdir ? system(env, *cmd, chdir: chdir) : system(env, *cmd)
end

def capture!(*cmd)
  out, err, st = Open3.capture3(*cmd)
  abort "FAILED: #{cmd.join(" ")}\n#{err}" unless st.success?
  out
end

def have?(tool) = system("command -v #{tool} >/dev/null 2>&1")

def image_exists?(name)
  system("docker", "image", "inspect", name, out: File::NULL, err: File::NULL)
end

def image_env(name, var)
  capture!("docker", "image", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", name)
    .lines.map(&:strip).grep(/\A#{var}=/) { |l| l.split("=", 2)[1] }.first
end

def port_busy?(port)
  TCPSocket.new("127.0.0.1", port).close
  true
rescue Errno::ECONNREFUSED
  false
end

# sqlite3 with FTS5 (the Android platform-tools sqlite3 lacks it — see REPORT.md).
def fts5_sqlite3_dir
  dirs = ENV["PATH"].split(":") + %w[/usr/bin /usr/local/bin /opt/homebrew/bin]
  dirs.uniq.each do |dir|
    bin = File.join(dir, "sqlite3")
    next unless File.executable?(bin)
    ok = Open3.capture3(bin, ":memory:", stdin_data: "CREATE VIRTUAL TABLE t USING fts5(c);\n")[2].success?
    return dir if ok
  end
  nil
end

# PATH for running the harness: the current interpreter's ruby (otherwise
# `#!/usr/bin/env ruby` in harness scripts picks the system ruby with rvm GEM
# paths — the mix fails with "can't find gem bundler"), cargo (rustup), and
# sqlite3-with-FTS5 first.
def harness_env
  path = [RbConfig::CONFIG["bindir"], File.expand_path("~/.cargo/bin"), fts5_sqlite3_dir, ENV["PATH"]].compact.join(":")
  env = { "PATH" => path }
  # Isolate harness scripts from the parent's bundler environment: rubygems
  # loads bundler/setup at startup via BUNDLER_SETUP/BUNDLE_GEMFILE, while the
  # harness is not a bundler project (minitest/stdlib) and has no Gemfile tie.
  %w[BUNDLER_SETUP BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_EXEC_OPTS RUBYOPT].each { |k| env[k] = nil }
  # A host redis on 6379 prevents the container from binding (harness uses
  # --network host); the Rails image already has no local redis, Elixir is
  # switched to the external one via REDIS_URL. See REPORT.md.
  env["ELIXIR_BENCH_ENV"] = { REDIS_URL: "redis://127.0.0.1:6379/0" }.to_json if port_busy?(6379)
  env
end

# CPU layout: server — 2 physical cores with SMT (4 threads), client — 4 other cores.
def cpu_sets
  return [ENV["BENCH_SERVER_CPUS"], ENV["BENCH_CLIENT_CPUS"]] if ENV["BENCH_SERVER_CPUS"] && ENV["BENCH_CLIENT_CPUS"]
  pairs = {}
  if linux? && Dir.exist?("/sys/devices/system/cpu")
    Dir["/sys/devices/system/cpu/cpu[0-9]*"].sort_by { |d| File.basename(d)[/\d+/].to_i }.each do |d|
      # siblings format: "0-1", "0,8" or a mix — parse both.
      sib = File.read(File.join(d, "topology", "thread_siblings_list")).strip.split(",")
                .flat_map { |part| a, b = part.split("-"); b ? (a.to_i..b.to_i).to_a : [a.to_i] }
      cpu = File.basename(d)[/\d+/].to_i
      pairs[cpu] = sib if sib.size > 1 && sib.first == cpu
    end
  end
  cores = pairs.keys.sort
  return [cores[0, 2].flat_map { |c| pairs[c] }.sort.join(","), cores[2, 4].join(",")] if cores.size >= 6
  %w[0,1,8,9 4-7]
end

def app_dir(app)
  # the harness looks for siblings: rails → «once-campfire», the rest (including
  # crails) → «once-campfire-<kind>»
  File.join(WORKSPACE, app == "rails" ? "once-campfire" : "once-campfire-#{app}")
end

def each_app(spec)
  list = spec.to_s.split(",").map(&:strip).reject(&:empty?)
  list = APP_ORDER if list.empty?
  unknown = list - APP_ORDER
  abort "Unknown apps: #{unknown.join(", ")}. Available: #{APP_ORDER.join(", ")}" unless unknown.empty?
  list
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

def ensure_downloaded!(spec)
  Rake::Task["download"].invoke(spec)
end

# ————— deps: host dependencies (Linux/Mac) —————

desc "Check and install host dependencies (docker, ruby, rust, node, sqlite3+FTS5, ffmpeg)"
task :deps do
  unless have?("docker")
    if darwin?
      sh?("brew", "install", "--cask", "docker") || abort("Install Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/")
    else
      abort "Docker not found — install it and start the daemon: https://docs.docker.com/get-docker/"
    end
  end
  sh!("docker", "version", "--format", "server={{.Server.Version}}")

  missing = %w[ruby node git curl ffmpeg sqlite3 python3].reject { |t| have?(t) }
  unless missing.empty?
    step "Missing: #{missing.join(", ")}"
    if linux?
      sh!("sudo", "apt-get", "update")
      sh!("sudo", "apt-get", "install", "-y", *%w[ruby-full nodejs git curl ffmpeg sqlite3 python3 build-essential cmake unzip pkg-config])
    elsif darwin?
      abort "Homebrew not found: brew.sh" unless have?("brew")
      sh!("brew", "install", *missing)
    end
  end

  # Rust for loadgen (rustc >= 1.88, edition 2024).
  cargo = File.expand_path("~/.cargo/bin/cargo")
  unless have?("cargo") || File.executable?(cargo)
    step "Installing rustup (needed for the load generator)..."
    sh!("bash", "-c", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal")
  end

  if fts5_sqlite3_dir.nil?
    puts "WARNING: no sqlite3 in PATH supports FTS5 — harness audits will fail."
    puts "Check: sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(c);'"
  end

  step "deps: OK (#{RbConfig::CONFIG["host_os"]})"
end

# ————— download: clones at pins —————

desc "Download competitor repositories at pinned revisions (download[c,go] — selectively)"
task :download, [:app] do |_t, args|
  FileUtils.mkdir_p(WORKSPACE)
  each_app(args[:app]).each do |app|
    dir = app_dir(app)
    if app == CRAILS_APP
      # Local repository: a symlink so the harness sees the source revision.
      FileUtils.ln_sf(REPO_ROOT, dir) unless File.symlink?(dir)
      step "crails: symlink #{dir} → #{REPO_ROOT}"
      next
    end
    cfg = APPS.fetch(app)
    if File.directory?(File.join(dir, ".git"))
      rev = capture!("git", "-C", dir, "rev-parse", "HEAD").strip
      if rev == cfg[:rev]
        step "#{app}: already at pin #{rev[0, 7]}"
      else
        step "#{app}: at #{rev[0, 7]}, checking out pin #{cfg[:rev][0, 7]}"
        sh?("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev]) ||
          (sh!("git", "-C", dir, "fetch", "origin") && sh!("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev]))
      end
    else
      step "#{app}: cloning #{cfg[:repo]} @ #{cfg[:rev][0, 7]}"
      sh!("git", "clone", cfg[:repo], dir)
      sh!("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev])
    end
    # Submodules recursively (Go: reference → once-campfire-rust → once-campfire).
    sh!("git", "-C", dir, "submodule", "update", "--init", "--recursive")
  end
end

# ————— build: docker images —————

desc "Build application docker images (build[rust] — selectively; REBUILD=1 to rebuild)"
task :build, [:app] do |_t, args|
  ensure_downloaded!(args[:app])
  each_app(args[:app]).each { |app| send("build_#{app}") }
end

def need_image?(app)
  image = IMAGE.fetch(app)
  if image_exists?(image) && ENV["REBUILD"] != "1"
    step "#{app}: image #{image} exists (REBUILD=1 to rebuild)"
    return false
  end
  true
end

def build_rails
  return unless need_image?("rails")
  dir = app_dir("rails")
  # The `redis:` line is cut from the Procfile: a host redis on 6379 prevents
  # the container one from binding (the harness runs --network host; Rails
  # talks to redis://localhost:6379 anyway). See REPORT.md.
  Dir.mktmpdir("rails-ctx") do |ctx|
    FileUtils.cp_r(File.join(dir, "."), ctx)
    FileUtils.rm_rf(File.join(ctx, ".git"))
    procfile = File.join(ctx, "Procfile")
    File.write(procfile, File.read(procfile).lines.reject { |l| l.start_with?("redis:") }.join)
    rev = APPS.fetch("rails")[:rev]
    sh!("docker", "build", "--build-arg", "APP_VERSION=benchmark", "--build-arg", "GIT_REVISION=#{rev}", "-t", IMAGE["rails"], ctx)
  end
end

def build_express
  return unless need_image?("express")
  sh!("docker", "build", "-t", IMAGE["express"], app_dir("express"))
end

def build_go
  return unless need_image?("go")
  sh!("docker", "build", "-t", IMAGE["go"], app_dir("go"))
end

def build_rust
  return unless need_image?("rust")
  rev = APPS.fetch("rust")[:rev]
  sh!("docker", "build", "--build-arg", "GIT_REVISION=#{rev}", "-t", IMAGE["rust"], app_dir("rust"))
end

def build_c
  return unless need_image?("c")
  dir = app_dir("c")
  # The C repository has no Dockerfile: the binary is built inside a fedora
  # container (vendored dependencies linked statically), the image — from
  # bench/image/Dockerfile.c.
  builder = "campfire-c-builder:1"
  unless image_exists?(builder)
    Dir.mktmpdir("c-builder") do |ctx|
      File.write(File.join(ctx, "Dockerfile"), <<~DOCKERFILE)
        FROM fedora:latest
        RUN dnf install -y --setopt=install_weak_deps=False \\
            clang make cmake perl autoconf automake libtool pkgconf-pkg-config \\
            zlib-devel git curl unzip python3 hostname openssl && dnf clean all
      DOCKERFILE
      sh!("docker", "build", "-t", builder, ctx)
    end
  end
  fetches = %w[picohttpparser sqlite zlib-ng yyjson openssl libxcrypt gumbo qrcodegen nghttp2 curl]
  script = fetches.map { |s| "bash vendor/scripts/#{s}.sh" }.join(" && ") +
           " && make deps-build && make MODE=bench build-app"
  sh!("docker", "run", "--rm", "--user", "#{Process.uid}:#{Process.gid}", "-e", "HOME=/tmp",
      "-v", "#{dir}:/src", "-w", "/src", builder, "bash", "-euo", "pipefail", "-c", script)
  work = File.join(dir, "bench", ".work", "image")
  FileUtils.rm_rf(work)
  FileUtils.mkdir_p(File.join(work, "tests", "fixtures"))
  FileUtils.cp(File.join(dir, "build", "bench", "campfire"), File.join(work, "campfire"))
  FileUtils.cp_r(File.join(dir, "tests", "fixtures", "assets"), File.join(work, "tests", "fixtures", "assets"))
  FileUtils.cp(File.join(dir, "bench", "image", "entrypoint.sh"), File.join(work, "entrypoint.sh"))
  sh!("docker", "build", "-f", File.join(dir, "bench", "image", "Dockerfile.c"), "-t", IMAGE["c"], work)
end

def build_elixir
  return unless need_image?("elixir")
  dir = app_dir("elixir")
  # The stage needs campfire-reference:app matching the pin of the reference
  # submodule (bin/export-assets verifies GIT_REVISION).
  ref_dir = File.join(dir, "reference")
  ref_rev = capture!("git", "-C", ref_dir, "rev-parse", "HEAD").strip
  unless image_exists?("campfire-reference:app") &&
         image_env("campfire-reference:app", "GIT_REVISION") == ref_rev
    step "elixir: building campfire-reference:app from the reference submodule"
    # GIT_REVISION is mandatory: bin/export-assets checks it against the submodule pin.
    sh!("docker", "build", "--build-arg", "GIT_REVISION=#{ref_rev}", "-t", "campfire-reference:app", ref_dir)
  end

  toolchain = "campfire-elixir:toolchain"
  unless image_exists?(toolchain) && ENV["REBUILD"] != "1"
    build_toolchain = lambda do |strip_pins|
      Dir.mktmpdir("elixir-ctx") do |ctx|
        FileUtils.cp_r(File.join(dir, "."), ctx)
        FileUtils.rm_rf(File.join(ctx, ".git"))
        df = File.join(ctx, "Dockerfile.dev")
        # trixie package pins rot (deb13u1 → u2 → …): the option drops exact versions.
        File.write(df, File.read(df).gsub(/(libvips-dev|ffmpeg)=\S+/, '\1')) if strip_pins
        sh?("docker", "build", "-f", df, "-t", toolchain, ctx)
      end
    end
    build_toolchain.call(false) || begin
      step "Elixir toolchain: exact package pins unavailable, building without them (see REPORT.md)..."
      build_toolchain.call(true) || abort("Elixir toolchain build failed")
    end
  end

  mix = lambda do |*args|
    sh!("docker", "run", "--rm", "--network", "host", "--user", "#{Process.uid}:#{Process.gid}",
        "-e", "HOME=/app", "-e", "TMPDIR=/app/var/tmp", "-e", "HEX_HOME=/app/.hex", "-e", "MIX_HOME=/app/.mix",
        "-e", "EXQLITE_USE_SYSTEM=1", "-e", "CAMPFIRE_NO_SERVER=1", "-e", "CAMPFIRE_JOBS_ADAPTER=disabled",
        "-e", "DATABASE_PATH=/app/var/test.sqlite3", "-v", "#{dir}:/app", "-w", "/app", toolchain, "mix", *args)
  end
  FileUtils.mkdir_p(File.join(dir, "var", "tmp"))
  mix.call("local.hex", "--force")
  mix.call("local.rebar", "--force")
  mix.call("deps.get")
  # Export assets from the reference image (docker mode of the script).
  sh!(File.join(dir, "bin", "export-assets"))
  sh!("docker", "build", "-t", IMAGE["elixir"], dir)
end

def build_crails
  return unless need_image?(CRAILS_APP)
  # Digest assets are generated by the Express build (the step is hidden in a
  # .gitignore comment — without it static_css returns 404; see REPORT.md).
  express = app_dir("express")
  express_assets = File.join(express, "assets", "generated", "public", "assets")
  unless File.directory?(express_assets)
    step "crails: generating assets via the Express build (requires node on the host)..."
    abort "Run `rake build[express]` first" unless File.directory?(File.join(express, ".git"))
    sh!("node", File.join(express, "bin", "build-assets.js"), chdir: express)
  end
  assets_dir = File.join(REPO_ROOT, "public", "assets")
  FileUtils.mkdir_p(assets_dir)
  FileUtils.cp_r(File.join(express_assets, "."), assets_dir)
  sh!("bash", File.join(REPO_ROOT, "bin", "docker-build.sh"))
end

# ————— harness: verifier + seed —————

desc "Clone the harness, apply the crails patch, bin/check, build loadgen, build the seed database"
task :harness do
  unless File.directory?(File.join(HARNESS, ".git"))
    step "Cloning harness #{HARNESS_REPO} @ #{HARNESS_REV[0, 7]}"
    sh!("git", "clone", HARNESS_REPO, HARNESS)
    sh!("git", "-C", HARNESS, "checkout", "-q", "-d", HARNESS_REV)
  end
  dirty = !capture!("git", "-C", HARNESS, "status", "--porcelain", "--untracked-files=no").strip.empty?
  unless dirty
    abort "Patch not found: #{HARNESS_PATCH}" unless File.readable?(HARNESS_PATCH)
    sh!("git", "-C", HARNESS, "apply", HARNESS_PATCH)
    step "harness: crails patch applied"
  end
  # CRails into the workspace (the harness looks for siblings).
  FileUtils.ln_sf(REPO_ROOT, app_dir(CRAILS_APP)) unless File.symlink?(app_dir(CRAILS_APP))

  env = harness_env
  sh!("cargo", "build", "--release", "--locked", "--manifest-path", File.join(HARNESS, "loadgen", "Cargo.toml"), env: env)
  sh!(File.join(HARNESS, "bin", "check"), env: env)

  fixtures = File.join(HARNESS, "fixtures", "default")
  if File.directory?(fixtures)
    step "harness: seed already built (#{fixtures})"
  else
    sh!(File.join(HARNESS, "bin", "seed"), env: env) # long: builds the Rails reference image + fixtures
  end
end

# ————— verify / benchmark / run —————

def run_henchmark(apps, extra)
  server, client = cpu_sets
  step "CPU: server=#{server} client=#{client}"
  sh!(File.join(HARNESS, "bin", "benchmark"), "--apps", apps.join(","),
      "--cpus", server, "--client-cpus", client,
      "--rounds", ENV.fetch("BENCH_ROUNDS", "3"),
      "--duration", ENV.fetch("BENCH_DURATION", "8"), *extra, env: harness_env)
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
  apps.each { |a| puts "  #{a}: #{data_by_app[a][:dir]} @ #{data_by_app[a][:rev]}" }
  puts "  Skipped incomplete runs: #{skipped.join(", ")}" unless skipped.empty?
  puts
end

desc "Full cycle: deps → download → build (crails last) → harness → verify → benchmark"
task :run do
  %w[deps download build harness verify benchmark].each { |t| Rake::Task[t].invoke }
end

task default: :run

# ————— Glob-safe aliases —————
# Bash expands `rake benchmark[crails]` into the existing benchmarks/
# directory (the class [crails] contains 's') — rake silently treats it as a
# file task and exits without doing work. Same awaits rails/express. Quoted
# arguments (`rake 'benchmark[crails]'`) work, but colon-style aliases that
# the glob cannot touch are more convenient:

%w[download build verify benchmark].each do |base|
  namespace base do
    APP_ORDER.each do |app|
      desc "#{base}: only #{app} (bracket-free alias)"
      task(app) { Rake::Task[base].invoke(app) }
    end
  end
end

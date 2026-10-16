# frozen_string_literal: true

# Full cycle of the comparative ONCE Campfire benchmark on this machine:
# the official basecamp/once-campfire-verification harness.
#
#   rake deps                  # host dependencies (Linux apt / macOS brew)
#   rake download              # clone all competitor repositories at pinned revisions (submodules recursively)
#   rake download[c,go]        # ...selectively
#   rake build                 # build docker images of all applications
#   rake build[rust]           # ...selectively
#   rake clean                 # remove built application images (keeps
#                              # builder/toolchain caches: campfire-c-builder,
#                              # campfire-elixir:toolchain, campfire-reference)
#   rake clean[c]              # ...selectively
#   rake rebuild               # clean + build of all applications
#   rake rebuild[crails]       # ...selectively
#   rake harness               # clone the harness, apply the crails patch,
#                              # bin/check, build loadgen, build the seed database (bin/seed)
#   rake verify                # preflight verification of each image (contracts, no load)
#   rake verify[c]
#   rake benchmark             # formal run: all applications, 3 rounds, interleaved
#   rake benchmark[c]          # ...a single application
#   rake report                # summary comparison table (routes × apps) from benchmarks/
#   rake run                   # EVERYTHING sequentially: deps→download→build→harness→verify→benchmark
#   rake compose:build         # build the reference image from GitHub (Dockerfile.github)
#   rake compose:up            # rebuild + start the reference stand on 127.0.0.1:5555
#   rake compose:down          # stop it (RESET=1 also drops the DB volumes)
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
#
# The tasks themselves are split into tasks/*.rake (deps, download, build,
# harness, benchmark, report, compose, aliases) — loaded at the bottom of
# this file; shared configuration and utilities live here.

require "bundler/setup" # Gemfile gems (terminal-table for report) — vendor/bundle

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

# Bash glob trap: `rake benchmark[crails]` gets expanded by the shell into the
# existing benchmarks/ directory (the character class [crails] contains 's';
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

# ————— Task files —————
# Tasks are split by area into tasks/*.rake (see the overview above);
# sorted load for deterministic registration.
Dir.glob(File.join(REPO_ROOT, "tasks", "*.rake")).sort.each { |path| load path }

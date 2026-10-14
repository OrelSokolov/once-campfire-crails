# frozen_string_literal: true

# Полный цикл сравнительного бенчмарка ONCE Campfire на этой машине:
# официальным harness'ом basecamp/once-campfire-verification.
#
#   rake deps                  # зависимости хоста (Linux apt / macOS brew)
#   rake download              # скачать все репозитории конкурентов на пинах (сабмодули рекурсивно)
#   rake download[c,go]        # ...выборочно
#   rake build                 # собрать docker-образы всех приложений
#   rake build[rust]           # ...выборочно
#   rake harness               # клонировать harness, применить патч crails,
#                             # bin/check, собрать loadgen, построить сид-базу (bin/seed)
#   rake verify                # preflight-верификация каждого образа (контракты без нагрузки)
#   rake verify[c]
#   rake benchmark             # формальный прогон: все приложения, 3 раунда, чередование
#   rake benchmark[c]          # ...одно приложение
#   rake run                   # ВСЁ последовательно: deps→download→build→harness→verify→benchmark
#
# Результаты: benchmarks/<UTC-таймстамп>-<apps>/ (summary.json + сырые сэмплы).
#
# Переменные окружения:
#   BENCH_SERVER_CPUS  cpuset сервера    (по умолчанию: автодетект 2 SMT-ядра, иначе 0,1,8,9)
#   BENCH_CLIENT_CPUS  cpuset генератора (по умолчанию: 4 отдельных ядра, иначе 4-7)
#   BENCH_ROUNDS       раунды (default 3), BENCH_DURATION сек (default 8)
#   REBUILD=1          пересобрать уже существующие образы
#   DRY_RUN=1          печатать команды без выполнения
#
# Замер и верификация требуют Linux (docker --network host, taskset в harness);
# на macOS доступны только deps/download/build.

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

# Bash-глоб ловушка: `rake benchmark[crails]` разворачивается шеллом в
# существующий каталог benchmarks/ (класс символов [crails] содержит 's';
# то же с rails/express), и rake молча трактует это как готовую file-task.
# Восстанавливаем намерение и подсказываем правильный синтаксис.
if (idx = ARGV.index("benchmarks"))
  ARGV[idx] = "benchmark"
  puts "ПРИМЕЧАНИЕ: аргумент развернулся в каталог benchmarks/ — запущен benchmark без фильтра."
  puts "Для одного приложения используй `rake benchmark:crails` или `rake 'benchmark[crails]'`."
end

# ————— Конфигурация: приложение → репозиторий на пине —————
# Пины — ревизии из таблицы README (upstream от 2026-10-09); rails — main
# на момент замера (ванильный 90b3300 не проходит текущий harness,
# см. REPORT.md). CRails — этот репозиторий, добавляется ПОСЛЕДНИМ:
# способ запуска меняется, держим его в хвосте очереди.
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
APP_ORDER  = APPS.keys + [CRAILS_APP] # crails строго последним

REPO_ROOT     = File.expand_path(__dir__)
WORKSPACE     = File.join(REPO_ROOT, "bench-workspace")
HARNESS       = File.join(WORKSPACE, "once-campfire-verification")
HARNESS_PATCH = File.join(REPO_ROOT, "benchmark", "harness-crails.patch")
RESULTS_DIR   = File.join(REPO_ROOT, "benchmarks")

# Имена образов — дефолты bench/compare.rb (RAILS_IMAGE и т.п. не нужны).
IMAGE = {
  "rails" => "once-campfire:app", "express" => "once-campfire-express:app",
  "go" => "once-campfire-go:app", "rust" => "campfire-rust:app",
  "c" => "once-campfire-c:app", "elixir" => "campfire-elixir:app",
  CRAILS_APP => "once-campfire-crails:app",
}.freeze

# ————— Утилиты —————

def darwin?  = RbConfig::CONFIG["host_os"].include?("darwin")
def linux?   = RbConfig::CONFIG["host_os"].include?("linux")
def dry_run? = ENV["DRY_RUN"] == "1"

def sh!(*cmd, env: {}, chdir: nil)
  puts "+ #{env.map { |k, v| "#{k}=#{v}" }.join(" ")} #{cmd.join(" ")}".strip
  return if dry_run?
  ok = chdir ? system(env, *cmd, chdir: chdir) : system(env, *cmd)
  abort "FAILED: #{cmd.join(" ")}" unless ok
end

# Как sh!, но false вместо abort — для повторных попыток.
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

# sqlite3 c FTS5 (Android platform-tools sqlite3 её не имеет — см. REPORT.md).
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

# PATH для запуска harness: cargo (rustup) и sqlite3-with-FTS5 впереди.
def harness_env
  path = [File.expand_path("~/.cargo/bin"), fts5_sqlite3_dir, ENV["PATH"]].compact.join(":")
  env = { "PATH" => path }
  # Хостовый redis на 6379 не даёт контейнерным забиндиться (harness --
  # network host); Rails-образ уже без локального redis, Elixir переключаем
  # на внешний через REDIS_URL. См. REPORT.md.
  env["ELIXIR_BENCH_ENV"] = { REDIS_URL: "redis://127.0.0.1:6379/0" }.to_json if port_busy?(6379)
  env
end

# CPU-раскладка: сервер — 2 физических ядра с SMT (4 треда), клиент — 4 других ядра.
def cpu_sets
  return [ENV["BENCH_SERVER_CPUS"], ENV["BENCH_CLIENT_CPUS"]] if ENV["BENCH_SERVER_CPUS"] && ENV["BENCH_CLIENT_CPUS"]
  pairs = {}
  if linux? && Dir.exist?("/sys/devices/system/cpu")
    Dir["/sys/devices/system/cpu/cpu[0-9]*"].sort_by { |d| File.basename(d)[/\d+/].to_i }.each do |d|
      # Формат siblings: "0-1", "0,8" или смесь — парсим и то, и другое.
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
  # harness ищет сиблинги: rails → «once-campfire», остальные (включая
  # crails) → «once-campfire-<kind>»
  File.join(WORKSPACE, app == "rails" ? "once-campfire" : "once-campfire-#{app}")
end

def each_app(spec)
  list = spec.to_s.split(",").map(&:strip).reject(&:empty?)
  list = APP_ORDER if list.empty?
  unknown = list - APP_ORDER
  abort "Неизвестные приложения: #{unknown.join(", ")}. Доступны: #{APP_ORDER.join(", ")}" unless unknown.empty?
  list
end

def save_results(label)
  return if dry_run?
  results = File.join(HARNESS, "tmp", "bench", "results")
  latest = Dir[File.join(results, "*")].select { |d| File.directory?(d) }.max_by { |d| File.mtime(d) }
  return puts "(нет результатов для копирования)" unless latest
  dest = File.join(RESULTS_DIR, "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{label}")
  FileUtils.mkdir_p(RESULTS_DIR)
  FileUtils.cp_r(latest, dest)
  puts "Результаты: #{dest}"
end

def ensure_downloaded!(spec)
  Rake::Task["download"].invoke(spec)
end

# ————— deps: зависимости хоста (Linux/Mac) —————

desc "Проверить и установить зависимости хоста (docker, ruby, rust, node, sqlite3+FTS5, ffmpeg)"
task :deps do
  unless have?("docker")
    if darwin?
      sh?("brew", "install", "--cask", "docker") || abort("Установи Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/")
    else
      abort "Docker не найден — установи и запусти демон: https://docs.docker.com/get-docker/"
    end
  end
  sh!("docker", "version", "--format", "server={{.Server.Version}}")

  missing = %w[ruby node git curl ffmpeg sqlite3 python3].reject { |t| have?(t) }
  unless missing.empty?
    puts "Отсутствуют: #{missing.join(", ")}"
    if linux?
      sh!("sudo", "apt-get", "update")
      sh!("sudo", "apt-get", "install", "-y", *%w[ruby-full nodejs git curl ffmpeg sqlite3 python3 build-essential cmake unzip pkg-config])
    elsif darwin?
      abort "Homebrew не найден: brew.sh" unless have?("brew")
      sh!("brew", "install", *missing)
    end
  end

  # Rust для loadgen (rustc >= 1.88, edition 2024).
  cargo = File.expand_path("~/.cargo/bin/cargo")
  unless have?("cargo") || File.executable?(cargo)
    puts "Устанавливаю rustup (нужен для генератора нагрузки)..."
    sh!("bash", "-c", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal")
  end

  if fts5_sqlite3_dir.nil?
    puts "ПРЕДУПРЕЖДЕНИЕ: ни один sqlite3 в PATH не поддерживает FTS5 — аудиты harness упадут."
    puts "Проверка: sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(c);'"
  end

  puts "deps: OK (#{RbConfig::CONFIG["host_os"]})"
end

# ————— download: клоны на пинах —————

desc "Скачать репозитории конкурентов на пинах (download[c,go] — выборочно)"
task :download, [:app] do |_t, args|
  FileUtils.mkdir_p(WORKSPACE)
  each_app(args[:app]).each do |app|
    dir = app_dir(app)
    if app == CRAILS_APP
      # Локальный репозиторий: символлинк, чтобы harness видел source-ревизию.
      FileUtils.ln_sf(REPO_ROOT, dir) unless File.symlink?(dir)
      puts "crails: символлинк #{dir} → #{REPO_ROOT}"
      next
    end
    cfg = APPS.fetch(app)
    if File.directory?(File.join(dir, ".git"))
      rev = capture!("git", "-C", dir, "rev-parse", "HEAD").strip
      if rev == cfg[:rev]
        puts "#{app}: уже на пине #{rev[0, 7]}"
      else
        puts "#{app}: на #{rev[0, 7]}, возвращаю пин #{cfg[:rev][0, 7]}"
        sh?("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev]) ||
          (sh!("git", "-C", dir, "fetch", "origin") && sh!("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev]))
      end
    else
      puts "#{app}: клонирую #{cfg[:repo]} @ #{cfg[:rev][0, 7]}"
      sh!("git", "clone", cfg[:repo], dir)
      sh!("git", "-C", dir, "checkout", "-q", "-d", cfg[:rev])
    end
    # Сабмодули рекурсивно (Go: reference → once-campfire-rust → once-campfire).
    sh!("git", "-C", dir, "submodule", "update", "--init", "--recursive")
  end
end

# ————— build: docker-образы —————

desc "Собрать docker-образы приложений (build[rust] — выборочно; REBUILD=1 пересобрать)"
task :build, [:app] do |_t, args|
  ensure_downloaded!(args[:app])
  each_app(args[:app]).each { |app| send("build_#{app}") }
end

def need_image?(app)
  image = IMAGE.fetch(app)
  if image_exists?(image) && ENV["REBUILD"] != "1"
    puts "#{app}: образ #{image} существует (REBUILD=1 для пересборки)"
    return false
  end
  true
end

def build_rails
  return unless need_image?("rails")
  dir = app_dir("rails")
  # Строка `redis:` из Procfile вырезается: хостовый redis на 6379 не даёт
  # контейнерному забиндиться (harness гоняет --network host; Rails и так
  # ходит на redis://localhost:6379). См. REPORT.md.
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
  # У репозитория C нет Dockerfile: бинарь собирается в контейнере fedora
  # (vendored-зависимости линкуются статически), образ — по bench/image/Dockerfile.c.
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
  # Этапу нужен campfire-reference:app, отождествлённый с пином сабмодуля
  # reference (bin/export-assets сверяет GIT_REVISION).
  ref_dir = File.join(dir, "reference")
  unless image_exists?("campfire-reference:app") &&
         image_env("campfire-reference:app", "GIT_REVISION") == capture!("git", "-C", ref_dir, "rev-parse", "HEAD").strip
    puts "elixir: строю campfire-reference:app из сабмодуля reference"
    sh!("docker", "build", "-t", "campfire-reference:app", ref_dir)
  end

  toolchain = "campfire-elixir:toolchain"
  unless image_exists?(toolchain) && ENV["REBUILD"] != "1"
    build_toolchain = lambda do |strip_pins|
      Dir.mktmpdir("elixir-ctx") do |ctx|
        FileUtils.cp_r(File.join(dir, "."), ctx)
        FileUtils.rm_rf(File.join(ctx, ".git"))
        df = File.join(ctx, "Dockerfile.dev")
        # Пины trixie-пакетов гниют (deb13u1 → u2 → …): опция снять точные версии.
        File.write(df, File.read(df).gsub(/(libvips-dev|ffmpeg)=\S+/, '\1')) if strip_pins
        sh?("docker", "build", "-f", df, "-t", toolchain, ctx)
      end
    end
    build_toolchain.call(false) || begin
      puts "Elixir toolchain: точные пины пакетов недоступны, собираю без них (см. REPORT.md)..."
      build_toolchain.call(true) || abort("Elixir toolchain не собрался")
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
  # Экспорт ассетов из reference-образа (docker-режим скрипта).
  sh!(File.join(dir, "bin", "export-assets"))
  sh!("docker", "build", "-t", IMAGE["elixir"], dir)
end

def build_crails
  return unless need_image?(CRAILS_APP)
  # Digest-ассеты генерируются сборкой Express (шаг спрятан в комментарии
  # .gitignore — без него static_css отдаёт 404; см. REPORT.md).
  express = app_dir("express")
  express_assets = File.join(express, "assets", "generated", "public", "assets")
  unless File.directory?(express_assets)
    puts "crails: генерирую ассеты сборкой Express (нужен node на хосте)..."
    abort "Сначала `rake build[express]`" unless File.directory?(File.join(express, ".git"))
    sh!("node", File.join(express, "bin", "build-assets.js"), chdir: express)
  end
  assets_dir = File.join(REPO_ROOT, "public", "assets")
  FileUtils.mkdir_p(assets_dir)
  FileUtils.cp_r(File.join(express_assets, "."), assets_dir)
  sh!("bash", File.join(REPO_ROOT, "bin", "docker-build.sh"))
end

# ————— harness: верификатор + сид —————

desc "Клонировать harness, применить патч crails, bin/check, собрать loadgen, построить сид-базу"
task :harness do
  unless File.directory?(File.join(HARNESS, ".git"))
    puts "Клонирую harness #{HARNESS_REPO} @ #{HARNESS_REV[0, 7]}"
    sh!("git", "clone", HARNESS_REPO, HARNESS)
    sh!("git", "-C", HARNESS, "checkout", "-q", "-d", HARNESS_REV)
  end
  dirty = !capture!("git", "-C", HARNESS, "status", "--porcelain", "--untracked-files=no").strip.empty?
  unless dirty
    abort "Патч не найден: #{HARNESS_PATCH}" unless File.readable?(HARNESS_PATCH)
    sh!("git", "-C", HARNESS, "apply", HARNESS_PATCH)
    puts "harness: патч crails применён"
  end
  # CRails в workspace (harness ищет сиблинги).
  FileUtils.ln_sf(REPO_ROOT, app_dir(CRAILS_APP)) unless File.symlink?(app_dir(CRAILS_APP))

  env = harness_env
  sh!("cargo", "build", "--release", "--locked", "--manifest-path", File.join(HARNESS, "loadgen", "Cargo.toml"), env: env)
  sh!(File.join(HARNESS, "bin", "check"), env: env)

  fixtures = File.join(HARNESS, "fixtures", "default")
  if File.directory?(fixtures)
    puts "harness: сид уже построен (#{fixtures})"
  else
    sh!(File.join(HARNESS, "bin", "seed"), env: env) # долго: строит Rails-reference-образ + фикстуры
  end
end

# ————— verify / benchmark / run —————

def run_henchmark(apps, extra)
  server, client = cpu_sets
  puts "CPU: сервер=#{server} клиент=#{client}"
  sh!(File.join(HARNESS, "bin", "benchmark"), "--apps", apps.join(","),
      "--cpus", server, "--client-cpus", client,
      "--rounds", ENV.fetch("BENCH_ROUNDS", "3"),
      "--duration", ENV.fetch("BENCH_DURATION", "8"), *extra, env: harness_env)
end

desc "Preflight-верификация образов: контракты без нагрузки (verify[c] — выборочно)"
task :verify, [:app] do |_t, args|
  abort "Верификация требует Linux (docker --network host + taskset)." unless linux?
  apps = each_app(args[:app])
  apps.each { |a| abort "Образ #{IMAGE[a]} не собран: rake build[#{a}]" unless image_exists?(IMAGE[a]) }
  run_henchmark(apps, ["--preflight"])
end

desc "Формальный бенчмарк (benchmark[c] — одно приложение; без аргумента — все, один прогон)"
task :benchmark, [:app] do |_t, args|
  abort "Бенчмарк требует Linux (docker --network host + taskset)." unless linux?
  apps = each_app(args[:app])
  apps.each { |a| abort "Образ #{IMAGE[a]} не собран: rake build[#{a}]" unless image_exists?(IMAGE[a]) }
  run_henchmark(apps, [])
  save_results(apps.join("_"))
end

desc "Полный цикл: deps → download → build (crails последним) → harness → verify → benchmark"
task :run do
  %w[deps download build harness verify benchmark].each { |t| Rake::Task[t].invoke }
end

task default: :run

# ————— Глоб-безопасные алиасы —————
# Bash разворачивает `rake benchmark[crails]` в существующий каталог
# benchmarks/ (класс [crails] содержит 's') — rake молча считает это
# file-task'ей и выходит без работы. То же ждёт rails/express. Аргументы
# в кавычках (`rake 'benchmark[crails]'`) работают, но удобнее алиасы
# через двоеточие, которые глоб не трогает:

%w[download build verify benchmark].each do |base|
  namespace base do
    APP_ORDER.each do |app|
      desc "#{base}: только #{app} (алиас без квадратных скобок)"
      task(app) { Rake::Task[base].invoke(app) }
    end
  end
end

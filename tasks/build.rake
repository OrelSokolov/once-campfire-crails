# frozen_string_literal: true

# ————— build / clean / rebuild: docker images —————

desc "Build application docker images (build[rust] — selectively; REBUILD=1 to rebuild)"
task :build, [:app] do |_t, args|
  ensure_downloaded!(args[:app])
  each_app(args[:app]).each { |app| send("build_#{app}") }
end

desc "Remove built application images (clean[rust] — selectively; builder/toolchain caches kept)"
task :clean, [:app] do |_t, args|
  each_app(args[:app]).each do |app|
    image = IMAGE.fetch(app)
    if image_exists?(image)
      step "#{app}: removing image #{image}"
      # -f: not blocked by stopped harness containers left after a run
      sh!("docker", "rmi", "-f", image)
    else
      step "#{app}: image #{image} not built"
    end
  end
end

desc "Force a clean rebuild of application images (rebuild[rust] — selectively)"
task :rebuild, [:app] do |_t, args|
  Rake::Task["clean"].invoke(args[:app])
  Rake::Task["build"].invoke(args[:app])
end

def ensure_downloaded!(spec)
  Rake::Task["download"].invoke(spec)
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

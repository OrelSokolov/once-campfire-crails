# frozen_string_literal: true

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

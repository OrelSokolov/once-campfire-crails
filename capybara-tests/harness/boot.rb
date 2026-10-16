# frozen_string_literal: true

require "net/http"
require "open3"
require "fileutils"
require "time"
require_relative "labels"

module Parity
  # Boots the parity target locally against a fresh copy of the shared seed.
  module Boot
    RAILS_ROOT = File.join(REPO_ROOT, "bench-workspace", "once-campfire")
    RUBY = ENV["PARITY_RUBY"] || File.join(Dir.home, ".asdf", "installs", "ruby", "4.0.7", "bin", "ruby")
    CHROME = %w[/usr/bin/google-chrome /usr/bin/chromium /snap/bin/chromium].find { |path| File.executable?(path) }

    class NotReady < StandardError; end

    def self.free_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    def self.wait_ready(base_url, label, log_file, timeout: 180)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      uri = URI("#{base_url}/up")
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        begin
          response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) { |http| http.get(uri.path) }
          return true if response.is_a?(Net::HTTPSuccess)
        rescue StandardError
          nil
        end
      end
      raise NotReady, "#{label} did not become ready at #{base_url}; see #{log_file}"
    end

    def self.quarantine_endpoints(db_file)
      system("sqlite3", db_file,
        "UPDATE push_subscriptions SET endpoint = 'https://127.0.0.1:9/push/' || id;" \
        "UPDATE webhooks SET url = 'http://127.0.0.1:9/hook/' || id;",
        exception: true)
    end

    STRIP_KEYS = %w[GEM_HOME GEM_PATH RUBY_VERSION MY_RUBY_HOME IRBRC RUBYOPT RUBYLIB]

    def self.clean_env(extra = {})
      # Strip everything bundler/rvm related: this process runs under
      # `bundle exec` of the suite's own Gemfile, and the booted targets must
      # resolve their own bundles from scratch. bundle exec leaks its setup
      # through BUNDLE_*/BUNDLER_* vars, notably BUNDLER_SETUP.
      env = ENV.reject { |key, _| STRIP_KEYS.include?(key) || key.start_with?("BUNDLE_", "BUNDLER_") }
      paths = env.fetch("PATH", "").split(File::PATH_SEPARATOR).reject { |dir| dir.include?(".rvm") || dir.include?(".asdf/shims") }
      env["PATH"] = [File.dirname(RUBY), *paths].uniq.join(File::PATH_SEPARATOR)
      env.merge(extra)
    end

    ProcessHandle = Struct.new(:pid, :log_file) do
      def stop
        Process.kill("TERM", pid) if Process.kill(0, pid) rescue nil
        Thread.new { Process.wait(pid, Process::WNOHANG) }.join(5)
        Process.kill("KILL", pid) if Process.kill(0, pid) rescue nil
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end

    def self.launch(cmd, args, cwd:, env:, log_file:)
      File.open(log_file, "a") do |io|
        io.puts "# parity launch #{Time.now.utc.iso8601}: #{cmd} #{args.join(' ')}"
      end
      pid = Process.spawn(clean_env.merge(env), cmd, *args, chdir: cwd,
        out: [log_file, "a"], err: [log_file, "a"])
      ProcessHandle.new(pid, log_file)
    end

    def self.copy_seed(target_dir)
      FileUtils.mkdir_p(target_dir)
      FileUtils.cp_r(File.join(SEED_DIR, "db"), File.join(target_dir, "db"))
      FileUtils.cp_r(File.join(SEED_DIR, "storage"), File.join(target_dir, "files"))
    end

    Server = Struct.new(:base_url, :processes, :data_dir, keyword_init: true) do
      def teardown
        processes&.each(&:stop)
        FileUtils.rm_rf(data_dir) if data_dir && ENV["PARITY_KEEP"] != "1"
      end
    end

    def self.rails(port:, redis_port:, fresh: true)
      raise "local ruby missing: #{RUBY}" unless File.executable?(RUBY)
      storage = File.join(RAILS_ROOT, "storage")
      if fresh
        FileUtils.rm_rf(storage)
        FileUtils.mkdir_p(storage)
        copy_seed(storage) # db/ → storage/db, seed storage/ → storage/files
        quarantine_endpoints(File.join(storage, "db", "production.sqlite3"))
      end

      FileUtils.mkdir_p(File.join(RAILS_ROOT, "log"))
      server_log = File.join(RAILS_ROOT, "log", "parity-server.log")
      redis_log = File.join(RAILS_ROOT, "log", "parity-redis.log")
      File.truncate(server_log, 0) if File.exist?(server_log)
      File.truncate(redis_log, 0) if File.exist?(redis_log)

      redis = launch("redis-server", ["--port", redis_port.to_s, "--save", "", "--appendonly", "no"],
        cwd: RAILS_ROOT, env: {}, log_file: redis_log)
      sleep 0.3

      base = {
        "RAILS_ENV" => "production",
        # bundle exec of the suite leaks its own Gemfile into children;
        # point the target explicitly at its own bundle.
        "BUNDLE_GEMFILE" => File.join(RAILS_ROOT, "Gemfile"),
        "SECRET_KEY_BASE" => Parity.seed_env.fetch("SECRET_KEY_BASE"),
        "DISABLE_SSL" => "true",
        "SKIP_TELEMETRY" => "true",
        "APP_VERSION" => "parity",
        "GIT_REVISION" => "parity",
        "REDIS_URL" => "redis://127.0.0.1:#{redis_port}",
        "RAILS_LOG_LEVEL" => "warn",
      }
      processes = [redis]
      begin
        # bin/rails loads bundler/setup itself via config/boot; avoids
        # `bundle exec` executable resolution against a foreign lockfile.
        server = launch(RUBY, ["bin/rails", "server", "-p", port.to_s, "-e", "production"],
          cwd: RAILS_ROOT, env: base, log_file: server_log)
        worker = launch(RUBY, ["bin/rake", "resque:work"],
          cwd: RAILS_ROOT, env: base.merge("QUEUE" => "*", "INTERVAL" => "0.1"), log_file: server_log)
        processes.concat([server, worker])
        base_url = "http://127.0.0.1:#{port}"
        wait_ready(base_url, "rails", server_log)
        Server.new(base_url: base_url, processes: processes, data_dir: nil)
      rescue StandardError
        processes.each(&:stop)
        raise
      end
    end

    def self.crails(port:, data_dir: nil)
      # data_dir given ⇒ restart after a mid-run crash: keep the accumulated
      # DB/files so cross-test state survives.
      if data_dir.nil?
        data_dir = File.join(RUN_DIR, "seed-crails-#{Time.now.to_i}-#{rand(1e6).to_i}")
        copy_seed(data_dir)
        quarantine_endpoints(File.join(data_dir, "db", "production.sqlite3"))
      end
      server_log = File.join(data_dir, "server.log")
      env = {
        "CRAILS_ENV" => "production",
        "SECRET_KEY_BASE" => Parity.seed_env.fetch("SECRET_KEY_BASE"),
        "DATABASE_URL" => "sqlite3://#{File.join(data_dir, 'db', 'production.sqlite3')}",
        "CAMPFIRE_STORAGE_ROOT" => File.join(data_dir, "files"),
        "CAMPFIRE_JOBS_DB" => File.join(data_dir, "db", "jobs.sqlite3"),
        "HTTP_PORT" => port.to_s,
        "WEB_CONCURRENCY" => "1",
        "RAILS_LOG_LEVEL" => "warn",
      }
      server = launch(File.join(REPO_ROOT, "bin", "app"), [], cwd: REPO_ROOT, env:, log_file: server_log)
      begin
        base_url = "http://127.0.0.1:#{port}"
        wait_ready(base_url, "crails", server_log, timeout: 60)
        Server.new(base_url: base_url, processes: [server], data_dir:)
      rescue StandardError
        server.stop
        raise
      end
    end

    def self.boot(target = TARGET)
      case target
      when "rails" then rails(port: free_port, redis_port: free_port)
      when "crails" then crails(port: free_port)
      else raise ArgumentError, "unknown target: #{target}"
      end
    end

    # Relaunch a server that died mid-run, keeping its data dir so state
    # accumulated by earlier tests survives. Returns a new Server.
    def self.restart(server)
      server.processes&.each(&:stop)
      case TARGET
      when "crails" then crails(port: free_port, data_dir: server.data_dir)
      when "rails" then rails(port: free_port, redis_port: free_port, fresh: false)
      else raise ArgumentError, "unknown target: #{TARGET}"
      end
    end
  end
end

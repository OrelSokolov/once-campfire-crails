# frozen_string_literal: true

# Wrapper around run.rb that hard-scrubs the environment of launched target
# servers (unsetenv_others), working around rvm/bundler leakage on this
# machine. See measure.rb for the backstory.

ENV["TARGET"] ||= "crails"

# Load (but don't boot) the harness, patch the launcher, then pull in the
# test_helper — its require of boot.rb is cached, and its boot-at-require
# happens after the patch is in place.
require_relative "harness/boot"

module Parity
  module Boot
    def self.launch(cmd, args, cwd:, env:, log_file:)
      File.open(log_file, "a") do |io|
        io.puts "# parity launch #{Time.now.utc.iso8601}: #{cmd} #{args.join(' ')}"
      end
      pid = Process.spawn(env.merge("HOME" => ENV.fetch("HOME", Dir.home), "PATH" => ENV.fetch("PATH")), cmd, *args,
        chdir: cwd, out: [log_file, "a"], err: [log_file, "a"],
        unsetenv_others: true)
      ProcessHandle.new(pid, log_file)
    end
  end
end

require_relative "test_helper"

Dir[File.expand_path("tests/*_test.rb", __dir__)].sort.each { |file| require file }

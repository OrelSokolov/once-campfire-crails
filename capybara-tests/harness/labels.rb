# frozen_string_literal: true

require "json"

module Parity
  SUITE_ROOT = File.expand_path("..", __dir__)
  REPO_ROOT = File.dirname(SUITE_ROOT)
  VERIFICATION_ROOT = File.join(REPO_ROOT, "bench-workspace", "once-campfire-verification")

  TARGET = ENV.fetch("TARGET", "rails")
  SEED_DIR = ENV["PARITY_SEED"] || File.join(VERIFICATION_ROOT, "fixtures", "default")
  ARTIFACTS = ENV["PARITY_ARTIFACTS"] || File.join(SUITE_ROOT, "artifacts", TARGET)
  RUN_DIR = File.join(SUITE_ROOT, "tmp")

  LABELS = JSON.parse(File.read(File.join(SEED_DIR, "labels.json")))

  def self.seed_env
    @seed_env ||= File.read(File.join(SEED_DIR, "reference.env")).each_line.each_with_object({}) do |line, env|
      env[Regexp.last_match(1)] = Regexp.last_match(2).strip if line.chomp =~ /\A([A-Z_][A-Z0-9_]*)=(.*)\z/
    end
  end

  PASSWORD = LABELS.fetch("passwords.all")

  EMAILS = LABELS.each_with_object({}) { |(key, value), h| h[key.delete_prefix("emails.").to_sym] = value if key.start_with?("emails.") }
  ROOMS  = LABELS.each_with_object({}) { |(key, value), h| h[key.delete_prefix("rooms.").to_sym] = value if key.start_with?("rooms.") }
  MESSAGES = LABELS.each_with_object({}) { |(key, value), h| h[key.delete_prefix("messages.").to_sym] = value if key.start_with?("messages.") }
  TRANSFERS = LABELS.each_with_object({}) { |(key, value), h| h[key.delete_prefix("transfers.").to_sym] = value if key.start_with?("transfers.") }
  AVATAR_TOKENS = LABELS.each_with_object({}) { |(key, value), h| h[key.delete_prefix("avatar_tokens.").to_sym] = value if key.start_with?("avatar_tokens.") }
  JOIN_CODE = LABELS.fetch("join_codes.signal")
end

# frozen_string_literal: true

# Teardown runs after minitest's autorun (at_exit hooks are LIFO: this one is
# registered before the test files pull in minitest).
at_exit do
  $parity_server&.teardown
end

require_relative "test_helper"

Dir[File.expand_path("tests/*_test.rb", __dir__)].sort.each { |file| require file }

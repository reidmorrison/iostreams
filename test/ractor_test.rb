# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Reads and writes with IOStreams in Ractors other than the main Ractor, each case in a Ractor of its own before the main
# Ractor uses that code, see test/ractor_cases.rb, in a process of its own, so that no other test has loaded what a case
# uses, or found what its classes find once, first.
class RactorTest < Minitest::Test
  describe IOStreams do
    it "reads and writes in Ractors other than the main Ractor" do
      skip("Ractors are checked from Ruby 4") unless defined?(Ractor) && RUBY_VERSION.to_i >= 4

      results  = JSON.parse(run_script(%(require "ractor_cases")).last)
      failures = results.reject { |_name, result| result == "ok" }

      assert_empty failures, failures.map { |name, result| "#{name}: #{result}" }.join("\n")
    end
  end
end

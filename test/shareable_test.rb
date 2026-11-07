# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The state of IOStreams that every Ractor can read: each test runs in a process of its own, which loads every
# constant, see ShareableState.
class ShareableTest < Minitest::Test
  describe IOStreams do
    before { skip("#{RUBY_ENGINE} has no Ractors") unless defined?(Ractor) }

    # Returns [Array<String>] the lines that the script prints, run in a process of its own, failing the test unless it
    # succeeds.
    def run_script(script)
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-I", __dir__, "-e", script)

      assert_predicate status, :success?, err
      out.split("\n")
    end

    it "holds a shareable value in every constant" do
      script = <<~RUBY
        require "shareable_state"
        require "iostreams"
        require "xlsxtream"
        # test/query/shareable_test.rb checks IOStreams::Query, which needs Active Record.
        puts ShareableState.unshareable_constants(ShareableState.modules(IOStreams, except: ["IOStreams::Query"]))
      RUBY

      assert_equal [], run_script(script)
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"

# The state of IOStreams that every Ractor can read: each test runs in a process of its own, which loads every
# constant, see ShareableState.
class ShareableTest < Minitest::Test
  describe IOStreams do
    before { skip("#{RUBY_ENGINE} has no Ractors") unless defined?(Ractor) }

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

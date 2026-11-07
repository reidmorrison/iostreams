# frozen_string_literal: true

require_relative "query_helper"

# The constants of IOStreams::Query, which test/shareable_test.rb leaves out, since they need Active Record, in a
# process of its own, see ShareableState.
class QueryShareableTest < Minitest::Test
  describe IOStreams::Query do
    before { skip("#{RUBY_ENGINE} has no Ractors") unless defined?(Ractor) }

    it "holds a shareable value in every constant" do
      script = <<~RUBY
        require "shareable_state"
        require "active_record"
        require "iostreams"
        puts ShareableState.unshareable_constants(ShareableState.modules(IOStreams::Query))
      RUBY

      assert_equal [], run_script(script)
    end
  end
end

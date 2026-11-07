# frozen_string_literal: true

require_relative "query_helper"
require_relative "../shareable_state"

# The constants of IOStreams::Query, which test/shareable_test.rb leaves out, since they need Active Record.
class QueryShareableTest < Minitest::Test
  describe IOStreams::Query do
    before { skip("#{RUBY_ENGINE} has no Ractors") unless defined?(Ractor) }

    it "holds a shareable value in every constant" do
      assert_equal [], ShareableState.unshareable_constants(ShareableState.modules(IOStreams::Query))
    end
  end
end

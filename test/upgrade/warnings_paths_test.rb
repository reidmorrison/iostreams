require_relative "../test_helper"
require "stringio"

# The forms that the deprecation warnings of v2.2 for paths and streams recommend give the same result in v2.2 and v3.0,
# and report no deprecation warning.
module Upgrade
  class WarningsPathsTest < Minitest::Test
    describe "the forms that the deprecation warnings for paths recommend" do
      describe "the IO supplied to IOStreams.stream, in place of #io_stream" do
        it "is the IO that the stream reads" do
          io    = StringIO.new("name\nJack\n")
          lines = refute_deprecated do
            lines = []
            IOStreams.stream(io).each(:line) { |line| lines << line }
            lines
          end

          assert_equal %w[name Jack], lines
          assert_predicate io, :eof?
        end

        it "is the IO that the stream writes" do
          io = StringIO.new
          refute_deprecated { IOStreams.stream(io).writer(:line) { |lines| lines << "Jack" } }

          assert_equal "Jack\n", io.string
        end
      end
    end
  end
end

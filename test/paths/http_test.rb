require_relative "../test_helper"

module Paths
  class HTTPTest < Minitest::Test
    describe IOStreams::Paths::HTTP do
      let :url do
        "http://google.com"
      end

      let :ssl_url do
        "https://google.com"
      end

      describe ".open" do
        it "reads http" do
          result = IOStreams::Paths::HTTP.new(url).read
          assert_includes result, "Google"
        end

        it "reads https" do
          result = IOStreams::Paths::HTTP.new(ssl_url).read
          assert_includes result, "Google"
        end

        it "does not support streams" do
          assert_raises URI::InvalidURIError do
            io = StringIO.new
            IOStreams::Paths::HTTP.new(io)
          end
        end
      end
    end
  end
end

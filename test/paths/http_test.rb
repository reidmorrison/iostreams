require_relative '../test_helper'

module Paths
  class HTTPTest < Minitest::Test
    describe IOStreams::Paths::HTTP do
      let :url do
        "http://example.com/index.html?count=10"
      end

      let :ssl_url do
        "https://example.com/index.html?count=10"
      end

      describe '.open' do
        it 'reads http' do
          result = IOStreams::Paths::HTTP.new(url).read
          assert_includes result, "<html>"
        end

        it 'reads https' do
          result = IOStreams::Paths::HTTP.new(ssl_url).read
          assert_includes result, "<html>"
        end

        it 'does not support streams' do
          assert_raises URI::InvalidURIError do
            io = StringIO.new
            IOStreams::Paths::HTTP.new(io)
          end
        end
      end
    end
  end
end

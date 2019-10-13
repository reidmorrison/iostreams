require_relative '../test_helper'

module Paths
  class HTTPTest < Minitest::Test
    describe IOStreams::Paths::HTTP do
      before do
        skip
      end

      let :uri do
        "http://example.com/index.html?count=10"
      end

      let :ssl_uri do
        "https://example.com/index.html?count=10"
      end

      describe '.open' do
        it 'reads http' do
          result = IOStreams::Paths::HTTP.open(uri) do |io|
            io.read
          end
          assert_includes result, "<html>"
        end

        it 'reads https' do
          result = IOStreams::Paths::HTTP.open(ssl_uri) do |io|
            io.read
          end
          assert_includes result, "<html>"
        end

        it 'does not support streams' do
          assert_raises ArgumentError do
            io = StringIO.new
            IOStreams::Paths::HTTP.open(io) do |http_io|
              http_io.read
            end
          end
        end
      end
    end
  end
end

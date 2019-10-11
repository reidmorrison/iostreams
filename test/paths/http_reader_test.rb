require_relative 'test_helper'

class HTTPReaderTest < Minitest::Test
  describe IOStreams::HTTP::Reader do
    let :uri do
      "http://example.com/index.html?count=10"
    end

    let :ssl_uri do
      "https://example.com/index.html?count=10"
    end

    describe '.open' do
      it 'reads http' do
        result = IOStreams::HTTP::Reader.open(uri) do |io|
          io.read
        end
        assert_includes result, "<html>"
      end

      it 'reads https' do
        result = IOStreams::HTTP::Reader.open(ssl_uri) do |io|
          io.read
        end
        assert_includes result, "<html>"
      end

      it 'does not support streams' do
        assert_raises ArgumentError do
          io = StringIO.new
          IOStreams::HTTP::Reader.open(io) do |http_io|
            http_io.read
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../test_helper"

module Paths
  class HTTPContentCodingTest < Minitest::Test
    describe IOStreams::Paths::HTTP::ContentCoding do
      let(:display_name) { "https://example.org/data.csv" }
      let(:gzipped) { Zlib.gzip("a,b\n1,2\n" * 1_000) }

      # Returns the content coding of a response with the supplied Content-Encoding.
      def coding(content_encoding = "gzip")
        IOStreams::Paths::HTTP::ContentCoding.of({"content-encoding" => content_encoding}, display_name)
      end

      # Returns a body that supplies the start of the gzip data, and then raises the supplied failure, as the body of a
      # response raises a failure of its request, such as a connection that fails.
      def failing_body(failure)
        body = StringIO.new(gzipped.byteslice(0, 100))
        body.define_singleton_method(:read) { |*args| super(*args) || raise(failure) }
        body
      end

      it "raises a failure of the request that the body raises as it is, rather than as a failure to decode the body" do
        # Errors that the zlib of JRuby also raises for data that it cannot decode.
        [Errno::EPIPE.new, IOError.new("closed stream")].each do |exception|
          failure = IOStreams::Errors::Unavailable.tag(exception, display_name)

          error = assert_raises(exception.class) { coding.reader(failing_body(failure), maximum_size: nil, &:read) }
          assert_same failure, error
        end
      end
    end
  end
end

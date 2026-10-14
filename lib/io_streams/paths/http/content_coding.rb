# frozen_string_literal: true

require "zlib"

module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      # The content coding of the body of a response, from its Content-Encoding header, such as gzip: how the server
      # encoded the body while it sent it, which is not part of the file, so the body is decoded as it is read.
      #
      # It knows the names of the content codings of HTTP, which of them mean that the body is not encoded, and the
      # format that decodes each of the others that can be decoded, so that the HTTP path only decides whether to ask
      # for them, see `ACCEPT_ENCODING`.
      #
      # Used internally by the HTTP path, which makes the request, and asks for the content coding of its response.
      class ContentCoding
        # The Accept-Encoding of a request whose body is decoded as it is read: the content codings that can be decoded.
        ACCEPT_ENCODING = "gzip"

        # The Accept-Encoding of a request for the body as it is stored, without a content coding.
        IDENTITY = "identity"

        # The values of a Content-Encoding header that mean that the body is not encoded, in lower case.
        UNENCODED = ["", "identity", "none"].freeze

        # The format that decodes each content coding that can be decoded, by its name in lower case. `x-gzip` is
        # another name for `gzip`.
        FORMATS = {"gzip" => IOStreams::Gzip, "x-gzip" => IOStreams::Gzip}.freeze

        # The number of bytes read at a time from the format that decodes the body.
        BLOCK_SIZE = 65_536

        # Returns [ContentCoding] the content coding of the body of the response to a request that accepted
        # `ACCEPT_ENCODING`, from its Content-Encoding header, which is `AS_SENT` when the body is not encoded.
        #
        # Raises [IOStreams::Errors::CommunicationsFailure] for any other content coding, such as `br`, `deflate`, a
        # body encoded twice, such as `gzip, gzip`, or a value that is not a content coding, naming it and the supplied
        # display name of the path, since the body would otherwise be read as the file, which it is not.
        def self.of(response, display_name)
          content_encoding = response["content-encoding"].to_s.strip
          name             = content_encoding.downcase
          return AS_SENT if UNENCODED.include?(name)

          format = FORMATS.fetch(name) do
            raise(Errors::CommunicationsFailure,
                  "Cannot decode the Content-Encoding #{content_encoding.inspect} of #{display_name}. To read the body as " \
                  "it is sent, supply headers: {\"Accept-Encoding\" => \"#{IDENTITY}\"}")
          end
          new(name, format, display_name)
        end

        def initialize(name, format, display_name)
          @name         = name
          @format       = format
          @display_name = display_name
        end

        # Yields [IOStreams::ChunkReader] the body decoded by the format of this content coding as the block reads it,
        # whose size is limited to `maximum_size` bytes, when it is supplied. Returns the result of the block.
        #
        # The body is yielded as it is when it is read as it is sent, see `AS_SENT`, or is empty, since an empty body has
        # nothing to decode, whatever its Content-Encoding says.
        #
        # Raises [IOStreams::Errors::CommunicationsFailure] when the body cannot be decoded, such as a gzip body that is
        # truncated or corrupt, with the failure of the format as its cause, see #decoding: before the block is called
        # when the start of the body cannot be decoded, otherwise from within the block, once it has read the data
        # before the failure. Also raises it from within the block when the body exceeds the maximum size once decoded.
        def reader(body, maximum_size:, &)
          return yield(body) if @format.nil? || body.eof?

          decode(body, maximum_size, &)
        end

        # Returns the result of the block, which reads the body as it is decoded.
        #
        # Raises [IOStreams::Errors::CommunicationsFailure] when the format cannot decode the body, naming the content
        # coding and the display name of the path, with the failure of the format as its cause.
        def decoding
          yield
        rescue Zlib::Error => e
          raise(failure(e))
        end

        # The content coding of a body that is read as it is sent: one that is not encoded, or the response to a request
        # that did not accept `ACCEPT_ENCODING`, whatever its Content-Encoding says, which then belongs to the file as it
        # is stored, or is read by the application, see the HTTP path.
        AS_SENT = new(nil, nil, nil).freeze

        private

        # Yields the body decoded by the format, see #reader.
        def decode(body, maximum_size)
          in_block = false
          @format.open_stream(:reader, body, {}, name: @name.to_sym) do |decoded|
            in_block = true
            result   = yield(Decoded.new(decoded, self, maximum_size))
            in_block = false
            result
          end
        rescue Zlib::Error => e
          # A failure that the block raises is its own. The format raises one as it starts to read the body, such as a
          # body that is not gzip, and as it finishes reading it.
          raise if in_block

          raise(failure(e))
        end

        # Returns [IOStreams::Errors::CommunicationsFailure] for the failure of the format to decode the body.
        #
        # It is not tagged with a kind of failure, such as `IOStreams::Errors::Unavailable`, since the whole body was
        # received, so the server sent a body that cannot be decoded, which sending the request again does not change.
        # A connection that closes before the whole body was received raises `Unavailable` as the body is read.
        def failure(error)
          Errors::CommunicationsFailure.new(
            "Cannot decode the Content-Encoding #{@name.inspect} of #{@display_name}: #{error.message}"
          )
        end

        # Reads the body once it is decoded, one block at a time: counts its bytes, so that the size of the file is
        # limited once it is decoded too, as well as the bytes received, since a small body can decode to far more
        # data, and asks its content coding to report a failure to decode it, see `ContentCoding#decoding`.
        class Decoded
          include ChunkReader

          def initialize(input, coding, maximum_size)
            @input        = input
            @coding       = coding
            @maximum_size = maximum_size
            @size         = 0
          end

          # Closed once the reader of the format that decodes the body is closed.
          def closed?
            @input.closed?
          end

          private

          # Returns [String] the next block of the decoded body, or nil at its end, see `ChunkReader`.
          #
          # Raises [IOStreams::Errors::CommunicationsFailure] once the decoded body exceeds the maximum size.
          def next_chunk
            chunk = @coding.decoding { @input.read(BLOCK_SIZE) }
            return unless chunk

            @size += chunk.bytesize
            if @maximum_size && (@size > @maximum_size)
              raise(Errors::CommunicationsFailure,
                    "Exceeded maximum allowed download size of #{@maximum_size} bytes once decompressed")
            end

            chunk
          end
        end
        private_constant :Decoded
      end
    end
  end
end

module IOStreams
  module Paths
    # Reads data that arrives one chunk at a time, such as the ranges of an S3 object or the body of an HTTP response,
    # like an IO, holding only the chunk that is being read.
    #
    # The class that includes it supplies the chunks: `#next_chunk` returns [String] the next chunk, or nil at the end
    # of the data, and `#closed?` answers whether it has been closed, after which every read raises IOError.
    module ChunkReader
      # Returns [String] upto `length` bytes, or nil at the end of the data, or with no length, the rest of the data,
      # like `IO#read`. The bytes replace the contents of `outbuf` when it is supplied.
      def read(length = nil, outbuf = nil)
        check_readable(length)
        data = length.nil? ? read_rest : read_upto(length)
        return data unless outbuf

        outbuf.replace(data.to_s)
        outbuf unless data.nil?
      end

      # Returns [String] upto `maxlen` bytes that have already been received, reading the next chunk only when they
      # have all been read, like `IO#readpartial`. Raises EOFError at the end of the data.
      def readpartial(maxlen, outbuf = nil)
        check_readable(maxlen)
        raise(EOFError, "end of file reached") if maxlen.positive? && !available?

        data = maxlen.zero? ? "".b : take(maxlen)
        outbuf ? outbuf.replace(data) : data
      end

      # Returns [true|false] whether all of the data has been read, reading the next chunk to find out, like
      # `IO#eof?`.
      def eof?
        check_readable
        !available?
      end

      alias eof eof?

      private

      # Raises like an IO when it is closed, or the length is negative.
      def check_readable(length = nil)
        raise(IOError, "closed stream") if closed?
        raise(ArgumentError, "negative length #{length} given") if length&.negative?
      end

      def read_upto(length)
        return "".b if length.zero?

        data = nil
        while length.positive? && available?
          part    = take(length)
          length -= part.bytesize
          data ? data << part : data = part
        end
        data
      end

      def read_rest
        data = "".b
        data << take while available?
        data
      end

      # Returns [String] upto `length` bytes of the current chunk, or with no length, the rest of it.
      def take(length = nil)
        part           = length ? @chunk.byteslice(@chunk_offset, length) : @chunk.byteslice(@chunk_offset..)
        @chunk_offset += part.bytesize
        part
      end

      # Returns [true|false] whether there are bytes to read, reading the next chunk that is not empty, which replaces
      # the current one, once the current one has all been read.
      def available?
        return true if @chunk && @chunk_offset < @chunk.bytesize

        while (chunk = next_chunk)
          next if chunk.empty?

          # Without copying a chunk that is already binary.
          @chunk        = chunk.encoding == Encoding::BINARY ? chunk : chunk.b
          @chunk_offset = 0
          return true
        end
        false
      end
    end
  end
end

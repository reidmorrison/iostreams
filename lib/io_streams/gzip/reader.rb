# frozen_string_literal: true

require "zlib"

module IOStreams
  module Gzip
    class Reader < IOStreams::Reader
      # The number of bytes read at a time.
      BLOCK_SIZE = 65_536

      def self.option_names
        []
      end

      # Read from a gzip stream, decompressing the contents as it is read.
      #
      # A gzip file can contain several members one after the other, for example when gzip files
      # are concatenated, and like `gunzip` the contents of every member are returned.
      #
      # The stream supplied to the block responds to #read, #readpartial and #eof?, see `IOStreams::ChunkReader`.
      def self.stream(input_stream)
        io = Members.new(input_stream)
        yield io
      ensure
        io&.close
      end

      # Reads every member of a gzip stream in turn.
      #
      # `Zlib::GzipReader` stops at the end of the first member, and returns any data it read past it
      # from `#unused`, so the next member is read from that data followed by the rest of the input.
      class Members
        include ChunkReader

        def initialize(input_stream)
          @input_stream = input_stream
          @gzip         = gzip_reader(input_stream)
        end

        # Finishes the gzip reader, without closing the input stream, which belongs to the caller.
        def close
          @gzip.finish unless @gzip.closed?
        end

        def closed?
          @gzip.closed?
        end

        private

        # Returns [String] the next data decompressed, or nil after the last member, see `IOStreams::ChunkReader`.
        def next_chunk
          loop do
            data = read_member
            return data if data
            return unless next_member?
          end
        end

        # Returns [String] the next data decompressed from the current member, or nil at its end, which MRI raises
        # EOFError for, and JRuby returns nil for.
        def read_member
          @gzip.readpartial(BLOCK_SIZE)
        rescue EOFError
          nil
        end

        # Starts reading the next member, returning [false] when there are no more members.
        # Zero bytes after the last member are ignored, as some tools pad gzip files with them.
        def next_member?
          return true unless @gzip.eof?

          remaining = @gzip.unused.to_s.b.sub(/\A\0+/n, "")
          while remaining.empty?
            block = @input_stream.read(BLOCK_SIZE)
            return false if block.nil?

            remaining = block.b.sub(/\A\0+/n, "")
          end

          # Finish the current member without closing the input stream, which the next member reads from.
          @gzip.finish
          @gzip = gzip_reader(Prefixed.new(remaining, @input_stream))
          true
        end

        # Bytes, like every other stream, rather than the external encoding, which `#readpartial` returns on JRuby.
        def gzip_reader(input_stream)
          ::Zlib::GzipReader.new(input_stream, external_encoding: Encoding::BINARY)
        end
      end

      # An input stream that returns the supplied data before reading from the input stream.
      class Prefixed
        include ChunkReader

        def initialize(data, input_stream)
          @data         = data
          @input_stream = input_stream
        end

        def closed?
          false
        end

        private

        # Returns [String] the supplied data, and then each block of the input stream, see `IOStreams::ChunkReader`.
        def next_chunk
          data  = @data
          @data = nil
          data || @input_stream.read(BLOCK_SIZE)
        end
      end
    end
  end
end

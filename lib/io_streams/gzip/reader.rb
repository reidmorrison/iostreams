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
      # `Zlib::GzipReader` stops at the end of the first member, and returns any data it read past it from `#unused`,
      # so the next member is read from that data followed by the rest of the input, see Source.
      class Members
        include ChunkReader

        def initialize(input_stream)
          @source = Source.new(input_stream)
          @gzip   = gzip_reader
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
        def next_member?
          return true unless @gzip.eof?

          @source.unread(@gzip.unused)
          return false unless skip_padding

          # Finish the current member without closing the input stream, which the next member reads from.
          @gzip.finish
          @gzip = gzip_reader
          true
        end

        # Skips any zero bytes before the next member, which some tools pad gzip files with, returning [false] when the
        # input ends without another member.
        def skip_padding
          loop do
            data = @source.read(BLOCK_SIZE)
            return false if data.nil?

            data = data.b.sub(/\A\0+/n, "")
            next if data.empty?

            @source.unread(data)
            return true
          end
        end

        # Bytes, like every other stream, rather than the external encoding, which `#readpartial` returns on JRuby.
        def gzip_reader
          ::Zlib::GzipReader.new(@source, external_encoding: Encoding::BINARY)
        end
      end

      # The input of the gzip reader of each member: the data that the gzip reader of the previous member read past its
      # end, see #unread, and then the rest of the input stream.
      #
      # It never reads more of the input stream than it is asked for, so that it holds no data that a gzip reader has not
      # seen, which would be lost when the gzip reader of the next member starts.
      class Source
        def initialize(input_stream)
          @input_stream = input_stream
          @unread       = nil
        end

        # Returns the supplied data before the rest of the input.
        def unread(data)
          return if data.nil? || data.empty?

          @unread = @unread ? data.b + @unread : data.b
        end

        # Returns [String] the next data, of at most `length` bytes, or nil at the end of the input. With a buffer, the
        # data replaces its contents, as `IO#read` does.
        def read(length, buffer = nil)
          data = @unread ? take_unread(length) : @input_stream.read(length)
          return data unless buffer

          data ? buffer.replace(data) : buffer.clear
          buffer if data
        end

        # Returns [String] the next data, like #read, but raises EOFError at the end of the input, like `IO#readpartial`,
        # which `Zlib::GzipReader` reads its input with.
        def readpartial(length, buffer = nil)
          read(length, buffer) || raise(EOFError, "end of file reached")
        end

        private

        def take_unread(length)
          data    = @unread.byteslice(0, length)
          @unread = @unread.bytesize > length ? @unread.byteslice(length..) : nil
          data
        end
      end
    end
  end
end

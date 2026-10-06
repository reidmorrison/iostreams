module IOStreams
  module Gzip
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Also the compression level, which only applies when writing.
      def self.valid_option_names
        option_names + %i[level]
      end

      # Read from a gzip stream, decompressing the contents as it is read.
      #
      # A gzip file can contain several members one after the other, for example when gzip files
      # are concatenated, and like `gunzip` the contents of every member are returned.
      #
      # The stream supplied to the block responds to #read, #readpartial and #eof?.
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
        def initialize(input_stream)
          @input_stream = input_stream
          @gzip         = ::Zlib::GzipReader.new(input_stream)
          # JRuby's Zlib::GzipReader does not implement #external_encoding.
          @encoding     = @gzip.respond_to?(:external_encoding) ? @gzip.external_encoding : Encoding.default_external
        end

        # Returns [String] up to `length` bytes, or the rest of the stream when `length` is nil.
        # Returns [nil] at the end of the stream when `length` is supplied.
        def read(length = nil, outbuf = nil)
          data = length.nil? ? read_all : read_upto(length)
          return data unless outbuf

          data.nil? ? outbuf.clear : outbuf.replace(data)
          data && outbuf
        end

        # Raises [EOFError] at the end of the stream.
        def readpartial(maxlen, outbuf = nil)
          read(maxlen, outbuf) || raise(EOFError, "end of file reached")
        end

        def eof?
          @gzip.eof? && !next_member?
        end

        alias eof eof?

        # Finishes the gzip reader, without closing the input stream, which belongs to the caller.
        def close
          @gzip.finish unless @gzip.closed?
        end

        private

        # Like `Zlib::GzipReader#read`, returns the data in the external encoding when no length is supplied.
        def read_all
          data = String.new(encoding: Encoding::BINARY)
          while (block = read_upto(65_536))
            data << block
          end
          data.force_encoding(@encoding)
        end

        def read_upto(length)
          return @gzip.read(0) if length.zero?

          loop do
            data = @gzip.read(length)
            return data if data && !data.empty?
            return nil unless next_member?
          end
        end

        # Starts reading the next member, returning [false] when there are no more members.
        # Zero bytes after the last member are ignored, as some tools pad gzip files with them.
        def next_member?
          return true unless @gzip.eof?

          remaining = @gzip.unused.to_s.b.sub(/\A\0+/n, "")
          while remaining.empty?
            block = @input_stream.read(65_536)
            return false if block.nil?

            remaining = block.b.sub(/\A\0+/n, "")
          end

          # Finish the current member without closing the input stream, which the next member reads from.
          @gzip.finish
          @gzip = ::Zlib::GzipReader.new(Prefixed.new(remaining, @input_stream))
          true
        end
      end

      # An input stream that returns the supplied data before reading from the input stream.
      class Prefixed
        def initialize(data, input_stream)
          @data         = data
          @input_stream = input_stream
        end

        def read(length = nil, outbuf = nil)
          data =
            if @data.empty?
              @input_stream.read(length)
            elsif length.nil?
              rest = @input_stream.read
              (@data + rest.to_s).tap { @data = +"" }
            else
              @data.slice!(0, length)
            end
          return data unless outbuf

          data.nil? ? outbuf.clear : outbuf.replace(data)
          data && outbuf
        end

        def readpartial(maxlen, outbuf = nil)
          read(maxlen, outbuf) || raise(EOFError, "end of file reached")
        end
      end
    end
  end
end

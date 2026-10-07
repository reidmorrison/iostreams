module IOStreams
  module Encode
    class Reader < IOStreams::Reader
      def self.option_names
        %i[encoding cleaner replace]
      end

      attr_reader :cleaner

      # Read a line at a time from a file or stream
      def self.stream(input_stream, **args)
        yield new(input_stream, **args)
      end

      # Apply encoding conversion when reading a stream.
      #
      # Parameters
      #   input_stream
      #     The input stream that implements #read
      #
      #   encoding: [String|Encoding]
      #     Encode returned data with this encoding.
      #     'US-ASCII':   Original 7 bit ASCII Format
      #     'ASCII-8BIT': 8-bit ASCII Format
      #     'UTF-8':      UTF-8 Format
      #     Etc.
      #     Default: 'UTF-8'
      #
      #     The data read is the contents of a file or stream, so it is treated as already being in this encoding,
      #     whatever encoding the input stream tags it with. So its characters are kept and only invalid characters
      #     are replaced, or raise an error.
      #
      #   replace: [String]
      #     The character to replace with when a character is invalid, or cannot be converted to the target encoding.
      #     nil: Don't replace any invalid characters. Encoding::UndefinedConversionError is raised.
      #     Default: nil
      #
      #   cleaner: [nil|symbol|Proc]
      #     Cleanse data read from the input stream.
      #     nil:           No cleansing
      #     :printable Cleanse all non-printable characters except \r and \n
      #     Proc/lambda    Proc to call after every read to cleanse the data
      #     Default: nil
      def initialize(input_stream, encoding: "UTF-8", cleaner: nil, replace: nil)
        super(input_stream)

        @converter = Converter.new(encoding: encoding, replace: replace)
        @cleaner   = Cleaner.new(cleaner, replace: replace) unless cleaner.nil?

        # More efficient read buffering only supported when the input stream `#read` method supports it.
        # Binary, since `IO#read` keeps the encoding of the buffer that it reads into.
        @read_cache_buffer = (String.new(encoding: Encoding::BINARY) unless @input_stream.method(:read).arity.between?(0, 1))
      end

      # Returns [String] data returned from the input stream, in the requested encoding.
      # Returns [nil] if end of file and no further data was read.
      #
      # A multi-byte character that is split by `size` is returned by the next read.
      # When `outbuf` is supplied, it is replaced with the data and returned, otherwise each read returns a new string.
      def read(size = nil, outbuf = nil)
        data = nil
        loop do
          block = read_block(size)
          if block.nil?
            data = @converter.finish
            break
          end

          data = @converter.convert(block, final: size.nil?)
          # Read again when the whole block is the start of a multi-byte character.
          break unless data.empty? && !block.empty?
        end

        if data.nil?
          outbuf&.clear
          return
        end

        # Data that is not converted, such as with `encoding: "BINARY"`, is the block that was read, which can be
        # the buffer that the next read reads into.
        data = data.dup if data.equal?(@read_cache_buffer)
        data = @cleaner.call(data) if @cleaner
        outbuf ? outbuf.replace(data) : data
      end

      # Returns [Encoding] the encoding of the data returned, or nil when it is returned unchanged.
      def encoding
        @converter.encoding
      end

      private

      # Returns [String] the next block of the input stream as binary data, or [nil] at the end of the stream.
      #
      # The data read is bytes, whatever encoding the input stream tags it with, such as `Encoding.default_external`
      # when the whole of a gzip file is read, so that it is treated the same whichever streams it was read through.
      def read_block(size)
        block = read_input(size)
        block.nil? || block.encoding == Encoding::BINARY ? block : block.b
      end

      def read_input(size)
        return @input_stream.read(size) unless @read_cache_buffer

        @input_stream.read(size, @read_cache_buffer)
      rescue ArgumentError
        # Handle arity of -1 when just 0..1
        @read_cache_buffer = nil
        @input_stream.read(size)
      end
    end
  end
end

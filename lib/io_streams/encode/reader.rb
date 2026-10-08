module IOStreams
  module Encode
    class Reader < IOStreams::Reader
      # The byte order mark that some programs, such as Excel, write at the start of UTF-8 text.
      BYTE_ORDER_MARK = "\uFEFF".freeze

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
      #     Like Ruby's `File.read`, "external:internal", such as "Windows-1252:UTF-8", reads the data in the external
      #     encoding and converts it to the internal encoding. A character that the internal encoding does not have
      #     raises Encoding::UndefinedConversionError, unless `replace` is supplied.
      #
      #     When reading UTF-8, a byte order mark at the start of the data is removed.
      #
      #   replace: [String]
      #     The character to replace with when a character is invalid, or cannot be converted to the target encoding.
      #     nil: Don't replace any invalid characters. IOStreams::Errors::InvalidEncoding, an
      #          Encoding::UndefinedConversionError, is raised with the byte offset of the invalid character.
      #          A read in blocks first returns the data before it, and the next read raises.
      #     Default: nil
      #
      #   cleaner: [nil|symbol|Proc]
      #     Cleanse data read from the input stream.
      #     nil:           No cleansing
      #     :printable Cleanse all non-printable characters except \r and \n
      #     Proc/lambda    Proc to call after every read to cleanse the data
      #     Default: nil
      def initialize(input_stream, encoding: Encode.default_encoding, cleaner: nil, replace: nil)
        super(input_stream)

        external, @internal = Encode.external_and_internal(encoding)
        @converter          = Converter.new(encoding: external, replace: replace)
        @internal           = nil if @internal == @converter.encoding
        @transcode_options  = replace.nil? ? {} : {invalid: :replace, undef: :replace, replace: replace}
        @cleaner            = Cleaner.new(cleaner, replace: replace) unless cleaner.nil?
        # Whether the start of the data, where UTF-8 text can begin with a byte order mark, is still to be read.
        @at_start           = @converter.encoding == Encoding::UTF_8

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
          data = remove_byte_order_mark(data) if @at_start && !data.empty?
          # Read again when the whole block is the start of a multi-byte character, or a byte order mark.
          break unless data.empty? && !block.empty?
        end

        if data.nil?
          outbuf&.clear
          return
        end

        # Data that is not converted, such as with `encoding: "BINARY"`, is the block that was read, which can be
        # the buffer that the next read reads into.
        data = data.dup if data.equal?(@read_cache_buffer)
        # The converter returns whole characters, so each block can be converted to the internal encoding on its own.
        data = data.encode(@internal, **@transcode_options) if @internal
        data = @cleaner.call(data) if @cleaner
        outbuf ? outbuf.replace(data) : data
      end

      # Returns [Encoding] the encoding of the data returned, or nil when it is returned unchanged.
      def encoding
        @internal || @converter.encoding
      end

      private

      # Returns [String] the first characters of the data without a byte order mark. Since the converter returns whole
      # characters, a byte order mark split across reads is in the first data that it returns.
      def remove_byte_order_mark(data)
        @at_start = false
        data.start_with?(BYTE_ORDER_MARK) ? data.byteslice(BYTE_ORDER_MARK.bytesize..) : data
      end

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

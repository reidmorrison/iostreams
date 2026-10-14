# frozen_string_literal: true

module IOStreams
  module Encode
    # Reads the text of the input stream in an encoding, converting it to another encoding, see #initialize, like an IO
    # that reads text in an encoding, such as `File.open(name, "r:Windows-1252:UTF-8")`: `#read`, `#readpartial`,
    # `#gets`, `#readline`, `#readlines`, `#each_line` and `#eof?`, see `IOStreams::ChunkReader`. So that code that
    # reads lines from the stream that `#reader` supplies, such as `CSV.new(io)`, works whether or not an encoding is set.
    #
    # Unlike an IO, which reads bytes with a length, `#read` with a length and `#readpartial` read text too, in whole
    # characters, which a reader of lines, such as `IOStreams::Line::Reader`, relies on.
    class Reader < IOStreams::Reader
      include ChunkReader

      # The byte order mark that some programs, such as Excel, write at the start of UTF-8 text.
      BYTE_ORDER_MARK = "\uFEFF"

      # The number of bytes read from the input stream at a time, apart from a read with a length, see #read.
      BLOCK_SIZE = 65_536

      def self.option_names
        %i[encoding cleaner replace]
      end

      # Raises ArgumentError for options that #initialize would raise for, see `IOStreams::Encode.check`.
      def self.check(**)
        Encode.check(**)
      end

      # Yields a reader that decodes the data read from the supplied input stream, see #initialize.
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
      #          Encoding::UndefinedConversionError, is raised with the byte offset of the invalid character, by every
      #          read that reaches it. A read with a length first returns the text before it, and the next read raises.
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
        @block_size        = BLOCK_SIZE
      end

      # Returns [String] the text of upto `length` bytes, or the rest of the text, see `IOStreams::ChunkReader#read`.
      #
      # A read with a length reads the input stream in blocks of that length, so that the data of the lines that
      # `IOStreams::Line::Reader` reads in blocks of its `buffer_size` is read in blocks of that size.
      def read(length = nil, outbuf = nil)
        @block_size = length if length.is_a?(Integer) && length.positive?
        super
      ensure
        @block_size = BLOCK_SIZE
      end

      # Returns [true|false] whether the input stream has been closed, such as the file that a path reads once the block
      # that reads it returns, after which every read raises IOError, see `IOStreams::ChunkReader`.
      def closed?
        @input_stream.respond_to?(:closed?) && @input_stream.closed?
      end

      private

      # Returns [Encoding] the encoding of the text that is read, see `IOStreams::ChunkReader`: the internal encoding, or
      # the encoding of the data, or binary when the data is read as it is.
      def chunk_encoding
        @internal || @converter.encoding || Encoding::BINARY
      end

      # Returns [String] the text of the next block of the input stream, in whole characters, or nil at its end, see
      # `IOStreams::ChunkReader`.
      #
      # Raises IOStreams::Errors::InvalidEncoding for data that is not valid, once the text before it has been returned,
      # and again each time that it is called after, since the converter keeps the error.
      def next_chunk
        block = read_block
        text(block.nil? ? @converter.finish : @converter.convert(block))
      end

      # Returns [String] the whole characters that the converter returned, without the byte order mark at the start of
      # the data, in the internal encoding, and cleansed. Returns nil at the end of the data.
      def text(data)
        return if data.nil?

        data = remove_byte_order_mark(data) if @at_start && !data.empty?
        # Data that is not converted, such as with `encoding: "BINARY"`, is the block that was read, which can be
        # the buffer that the next block is read into.
        data = data.dup if data.equal?(@read_cache_buffer)
        # The converter returns whole characters, so each block can be converted to the internal encoding on its own.
        data = data.encode(@internal, **@transcode_options) if @internal
        data = @cleaner.call(data) if @cleaner
        data
      end

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
      def read_block
        block = read_input
        block.nil? || block.encoding == Encoding::BINARY ? block : block.b
      end

      def read_input
        return @input_stream.read(@block_size) unless @read_cache_buffer

        @input_stream.read(@block_size, @read_cache_buffer)
      rescue ArgumentError
        # Handle arity of -1 when just 0..1
        @read_cache_buffer = nil
        @input_stream.read(@block_size)
      end
    end
  end
end
